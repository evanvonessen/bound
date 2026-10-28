//
//  RingBuffer.swift
//  DeltaCore
//
//  Created by Riley Testut on 6/29/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//
//  Heavily based on Michael Tyson's TPCircularBuffer (https://github.com/michaeltyson/TPCircularBuffer)
//

import Foundation
import Darwin.Mach.machine.vm_types

private func trunc_page(_ x: vm_size_t) -> vm_size_t
{
    return x & ~(vm_page_size - 1)
}

private func round_page(_ x: vm_size_t) -> vm_size_t
{
    return trunc_page(x + (vm_size_t(vm_page_size) - 1))
}

/// One producer owns writes and one consumer owns reads/reset. Lifecycle
/// changes must quiesce those owners before resetting or replacing storage.
@objc(DLTARingBuffer) @objcMembers
public class RingBuffer: NSObject
{
    public var isEnabled: Bool {
        get { OSAtomicAdd32Barrier(0, self.enabledState) != 0 }
        set {
            let desired: Int32 = newValue ? 1 : 0
            while true {
                let current = OSAtomicAdd32Barrier(0, self.enabledState)
                if current == desired || OSAtomicCompareAndSwap32Barrier(current, desired, self.enabledState) { return }
            }
        }
    }
    
    public var availableBytesForWriting: Int {
        return self.bufferLength - Int(OSAtomicAdd32Barrier(0, self.usedBytesCount))
    }
    
    public var availableBytesForReading: Int {
        return Int(OSAtomicAdd32Barrier(0, self.usedBytesCount))
    }
    
    private var head: UnsafeMutableRawPointer {
        let head = self.buffer.advanced(by: self.headOffset)
        return head
    }
    
    private var tail: UnsafeMutableRawPointer {
        let head = self.buffer.advanced(by: self.tailOffset)
        return head
    }
    
    private let buffer: UnsafeMutableRawPointer
    private var bufferLength = 0
    private var tailOffset = 0
    private var headOffset = 0
    // Single producer owns headOffset; single consumer owns tailOffset.
    // Barrier atomics publish copied bytes before a reader observes the count,
    // and publish consumed bytes before the producer reuses that storage.
    // A dedicated atomic allocation avoids overlapping Swift `inout` access
    // scopes when both owners call the C atomic API concurrently.
    private let usedBytesCount: UnsafeMutablePointer<Int32>
    private let enabledState: UnsafeMutablePointer<Int32>
    
    public init?(preferredBufferSize: Int)
    {
        // Byte counts are published through an Int32 atomic. Reject invalid
        // or unrepresentable capacities before rounding or allocating pages.
        guard preferredBufferSize > 0,
              preferredBufferSize <= Int(Int32.max) - Int(vm_page_size - 1) else { return nil }
        
        // To handle race conditions, repeat initialization process up to 3 times before failing.
        for _ in 1...3
        {
            let length = round_page(vm_size_t(preferredBufferSize))
            self.bufferLength = Int(length)
            
            var bufferAddress: vm_address_t = 0
            guard vm_allocate(mach_task_self_, &bufferAddress, vm_size_t(length * 2), VM_FLAGS_ANYWHERE) == ERR_SUCCESS else { continue }
            
            guard vm_deallocate(mach_task_self_, bufferAddress + length, length) == ERR_SUCCESS else {
                vm_deallocate(mach_task_self_, bufferAddress, length)
                continue
            }
            
            var virtualAddress: vm_address_t = bufferAddress + length
            var current_protection: vm_prot_t = 0
            var max_protection: vm_prot_t = 0
            
            guard vm_remap(mach_task_self_, &virtualAddress, length, 0, 0, mach_task_self_, bufferAddress, 0, &current_protection, &max_protection, VM_INHERIT_DEFAULT) == ERR_SUCCESS else {
                vm_deallocate(mach_task_self_, bufferAddress, length)
                continue
            }
            
            guard virtualAddress == bufferAddress + length else {
                vm_deallocate(mach_task_self_, virtualAddress, length)
                vm_deallocate(mach_task_self_, bufferAddress, length)
                
                continue
            }
            
            self.buffer = UnsafeMutableRawPointer(bitPattern: UInt(bufferAddress))!
            self.usedBytesCount = .allocate(capacity: 1)
            self.usedBytesCount.initialize(to: 0)
            self.enabledState = .allocate(capacity: 1)
            self.enabledState.initialize(to: 1)
            return
        }
        
        return nil
    }
    
    deinit
    {
        self.enabledState.deinitialize(count: 1)
        self.enabledState.deallocate()
        self.usedBytesCount.deinitialize(count: 1)
        self.usedBytesCount.deallocate()
        let address = UInt(bitPattern: self.buffer)
        vm_deallocate(mach_task_self_, vm_address_t(address), vm_size_t(self.bufferLength * 2))
    }
}

public extension RingBuffer
{
    /// Publishes one complete producer chunk, or drops it when the consumer
    /// has not freed enough space. Dropping the whole chunk preserves PCM frame
    /// alignment and never changes the consumer-owned read position.
    @objc(writeBuffer:size:)
    @discardableResult func write(_ buffer: UnsafeRawPointer, size: Int) -> Int
    {
        guard self.isEnabled, size > 0 else { return 0 }
        guard size <= self.availableBytesForWriting else { return 0 }

        memcpy(self.head, buffer, size)
        self.decrementAvailableBytes(by: size)
        return size
    }

    /// Copies `size` bytes from ring buffer to `buffer` if possible. Otherwise, copies as many as possible.
    @objc(readIntoBuffer:preferredSize:)
    @discardableResult func read(into buffer: UnsafeMutableRawPointer, preferredSize: Int) -> Int
    {
        guard self.isEnabled, preferredSize > 0 else { return 0 }
        let size = min(preferredSize, self.availableBytesForReading)
        guard size > 0 else { return 0 }
        memcpy(buffer, self.tail, size)
        
        self.incrementAvailableBytes(by: size)
        
        return size
    }
    
    /// Discards queued data on the consumer owner. Call only while serialized
    /// with reads (or after both audio callbacks have stopped).
    func reset()
    {
        let size = self.availableBytesForReading
        self.incrementAvailableBytes(by: size)
    }
}

private extension RingBuffer
{
    func incrementAvailableBytes(by size: Int)
    {
        self.tailOffset = (self.tailOffset + size) % self.bufferLength
        OSAtomicAdd32Barrier(-Int32(size), self.usedBytesCount)
    }
    
    func decrementAvailableBytes(by size: Int)
    {
        self.headOffset = (self.headOffset + size) % self.bufferLength
        OSAtomicAdd32Barrier(Int32(size), self.usedBytesCount)
    }
}

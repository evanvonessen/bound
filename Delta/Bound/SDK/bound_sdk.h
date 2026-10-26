#ifndef BOUND_GAME_SDK_H
#define BOUND_GAME_SDK_H
/* Byte and committed-mailbox primitives. No native game addresses, payload
 * rules, persistence policy or transport authority belong in this interface.
 * Volatile access order is intentional: callers retain their existing safe
 * boundary and perform the final sequence/index publication only after data. */
static inline unsigned short bound_sdk_load_le16(const volatile unsigned char *p) {
    return p[0]|(unsigned short)p[1]<<8;
}
static inline unsigned bound_sdk_load_le32(const volatile unsigned char *p) {
    return p[0]|(unsigned)p[1]<<8|(unsigned)p[2]<<16|(unsigned)p[3]<<24;
}
static void bound_sdk_store_le32(volatile unsigned char *p,unsigned value) {
    p[0]=value; p[1]=value>>8; p[2]=value>>16; p[3]=value>>24;
}
#define BOUND_SDK_UNCOMMITTED_SEQUENCE(sequence) (!(sequence) || ((sequence)&1))
#define BOUND_SDK_ADVANCE_SEQUENCE(destination,previous) do { \
    (destination)=(previous)+2; \
    if(BOUND_SDK_UNCOMMITTED_SEQUENCE(destination)) (destination)=2; \
} while(0)
static inline int bound_sdk_same_committed_sequence(unsigned before,unsigned after) {
    return !BOUND_SDK_UNCOMMITTED_SEQUENCE(before) && before==after;
}
#endif

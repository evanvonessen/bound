// Verified release downloads and frozen exact profiles; see recognized-multi-red-roms.json.
import Foundation

enum BoundRecognizedROMs {
    static let all: [BoundROMCleanupIdentity] = [
        .init(sha256: "02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79", gameID: "4b792d8f8b86e1a65b27965bb523fe0a48a20190", evidence: "https://github.com/evanvonessen/multi_red/releases/download/multiplayer-02f97ffa88f7/multiplayer.gba"),
        .init(sha256: "15f7be08ae295828ae95e2b7ede00e553ac5cbbea2b2e5789ad9a98494fe7707", gameID: "d07afd119bc1abfc499fe3a6c7eb7aaa629bfd18", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-2e4ec6774a50-faf71208a1e4/rrbin-integrated.gba"),
        .init(sha256: "1abad2893274693299c4d79ecfc1952a4b0c5c96e3070470d4e64b6c28d38047", gameID: "b60454b7b94d4f31f8c75a4e0bf04114b8698e6e", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-ccf628d8fce4-c16c194dba3f/rrbin-integrated.gba"),
        .init(sha256: "34d2320d582a2a2791d2168ac07cfe3880a6af72a80b34f4e8557c4727f0ec3d", gameID: "90a8077cd42c2d8f053e6412250e3276b7c45316", evidence: "PrototypeConfiguration/game-profiles/debug-native-defaults/manifest.json"),
        .init(sha256: "3552b07fdb942aab0950c1d025d51fca4cd0834b49c245f1ac3071f98de74e88", gameID: "8d5561f1aa12be730fa7c0989c3544f2d8b59e9b", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-af674efdd8c0-76e77e319a50/rrbin-integrated.gba"),
        .init(sha256: "395d8e6b67da9e6f287398cefc39dfc57c3b0b05c7e2b6b083f79a5a8c2b6316", gameID: "29fe61f1ca2bc49e0f82608e093194021a1db52d", evidence: "PrototypeConfiguration/game-profiles/friends-multiview/manifest.json"),
        .init(sha256: "433e308025f5ec0dfc389f323092de35fbbc19dfcb9046656d4de0245523e271", gameID: "d6f7b4abda4247613ac131de46aa17fd6f6522d9", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-fc66f206d66b-f9ab9c63d526/rrbin-integrated.gba"),
        .init(sha256: "46fc4412b7a382ea939811c4d4e76186d3fcb4bdfd2f847d99716b3420f10523", gameID: "9dbe48b6245e6f81c4b1b61189edaf1f97998ed9", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-baf10d537096-485d653642f2/rrbin-integrated.gba"),
        .init(sha256: "491cf0cce7f6af425023a0f0ec0cef892546106060f70e18b80b6106e0099caa", gameID: "91552ae724c6b8036fb7d2dbb2aca2ad61d27a00", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-8741e2165806-e209d1dccc25/rrbin-integrated.gba"),
        .init(sha256: "8bf5b9675e0e34e785b0a40eb2d8120a1d2d6874890c4f6d2f43b5d1d3ab90fb", gameID: "5e572144dc845a8b3576b38672447c6507d9f47d", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-8d8a12d3f8e8-c55d0f7f3209/rrbin-integrated.gba"),
        .init(sha256: "978385f66075f4819529183ec3867709a9f90547797b3e0cda5d2f023ad5a27a", gameID: "0a6a42a0492f31886b88823b68a7c936c94ea202", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-463269916e7d-f467ee5a08b8/rrbin-integrated.gba"),
        .init(sha256: "98bcdf92e72034044f18558f0c46d94612269d1411007512a5fc1162a3409789", gameID: "cc29900f6e0f2cd457f9791495fb171f21d9382d", evidence: "https://github.com/evanvonessen/multi_red/releases/download/cartridge-98bcdf92e7203404/rrbin-integrated.gba"),
        .init(sha256: "9f0740e30ae7f71da3d993fb3c2ad84dadfe1dd23f1d08480f81582692567dde", gameID: "4cdd2822f0a9d1a623d0695b4e068cc2432d0dd6", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-d1e878467a3e-61870dd575bb/rrbin-integrated.gba"),
        .init(sha256: "b316e4b67b8a26afd00a6b764d49a11fe89be8182cdd7b79da862ad7f308aeaf", gameID: "d1327a88ef3710cde490e037c9227e5cf7790672", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-3358887cc4b6-b26ac1a6fdee/rrbin-integrated.gba"),
        .init(sha256: "b457621ee8ec889b44cf2498ba6f9121e497b57f8de246eccdf0e0828ba6e906", gameID: "cad2fe702de92b22b65a7ca97302eac5d421e95b", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-250923f0c65d-220d42ae7389/rrbin-integrated.gba"),
        .init(sha256: "c14ccd452d8d7efe7f8f11dadce6a2e955f53127620c1218c550fab059aae79b", gameID: "1ec7d100682030f8c42d93cdd28da7ebd25d22d7", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-f26e5cd299ec-ffadb2e2b82e/rrbin-integrated.gba"),
        .init(sha256: "d2a206998f67db500f88ccc197fc9977ebd437f714661916abbc7b484e38370a", gameID: "93cd279aa3bf0f6d246e4fec60e676225b649109", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-863ef9aa4681-518fa2c785b2/rrbin-integrated.gba"),
        .init(sha256: "e81c5d68e06a654d9e5ce5917742f2083ff3b884fe087d14a1026c26be7c21cd", gameID: "a9b3bc1d3415990afa63835168cab968a9a3bcc4", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-5c4e05789172-a5528fc0339d/rrbin-integrated.gba"),
        .init(sha256: "ed07daecb5d38278dd6a0452b3113bab68bfb0fdc0a4cf9d95caff120404700c", gameID: "ab688cea9878b1041fd638ef525a8b264f924acf", evidence: "https://github.com/evanvonessen/multi_red/releases/download/rom-d29a1aa2f479-c7e11a99e894/rrbin-integrated.gba"),
        .init(sha256: "fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00", gameID: "51ebbe0108c0c18bb5bfcbef42ed3d19a4cfd606", evidence: "PrototypeConfiguration/integrated-game.json"),
    ]
}

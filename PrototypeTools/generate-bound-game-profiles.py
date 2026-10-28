#!/usr/bin/env python3
"""Generate exact supported profiles; the legacy pair is frozen, never rebuilt."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / 'PrototypeConfiguration/game-profiles/original-independent'
OLD_HEADER = 'b8fcef0e0c265f6cedc074cf7f24747bbdd84d67c82e0c3ad7e4296c9e996ed1'
OLD_ROM = '8bf5b9675e0e34e785b0a40eb2d8120a1d2d6874890c4f6d2f43b5d1d3ab90fb'
PRE_SHINY_ROOT = ROOT / 'PrototypeConfiguration/game-profiles/pre-shiny-magikarp'
PRE_SHINY_MANIFEST = '65b9474edf1750905f451125af99b56b34d4f03f69423fa01bc328f3cc34840f'
PRE_SHINY_HEADER = '516ebde23ec5c0950c3fc344af1c5006eae470c3b212c05da20d12de166ecf78'
PRE_LINKS_ROOT = ROOT / 'PrototypeConfiguration/game-profiles/pre-links-menu'
PRE_LINKS_MANIFEST = '1f74b6a909a3f58fd8ca5fd431984bead85301d30ec7e816023cbb59d61656df'
PRE_LINKS_HEADER = '02050bd1f651ebbada6b87796503220b3bdce640f4b80236f750fa9466523562'
LINKS_MENU_ROOT = ROOT / 'PrototypeConfiguration/game-profiles/native-links-menu'
LINKS_MENU_MANIFEST = '2c84de5e72e739bf9f19910763e4780a38882ec01cf49cbe09c544204a84330f'
LINKS_MENU_HEADER = 'e17b4ec56368a0e3b724688785d23e2f29cdd3a881fd1defdf348847a554d9d5'
ELIMINATION_ROOT = ROOT / 'PrototypeConfiguration/game-profiles/native-elimination'
ELIMINATION_MANIFEST = 'f629e5ecdf167290a3b4871ec2c4be3b2f42b1bcf93d758356cc95660d19230a'
ELIMINATION_HEADER = '909b6fe2f8c877c878a82cbd3f8ac4c703010fc6f9e9495760b47aeb0b1f23a0'
# Reviewed together when importing a new exact ROM; never infer its library ID.
CURRENT_ROM = '961747cac29f351ea62162ef1e819d655738f460e3884e4f41834219b40d10ab'
CURRENT_GAME_ID = 'b3d909ad22352fbcb28c89fc6cf88dab1bc0bbe1'

def generate():
    original_manifest = (OLD / 'manifest.json').read_bytes()
    assert hashlib.sha256(original_manifest).hexdigest() == '96ca7c44fb56745dc9c41b220d0a6ee035d4f16df77348d4d31e1369f6240ad3', 'Frozen original manifest changed'
    old = json.loads(original_manifest)
    header = (OLD / 'BoundGameABI.h').read_bytes()
    assert hashlib.sha256(header).hexdigest() == OLD_HEADER, 'Frozen original ABI changed'
    assert old['integrated_sha256'] == OLD_ROM and old['contract']['save_state_layout'] == 5
    pre_shiny_bytes = (PRE_SHINY_ROOT / 'manifest.json').read_bytes()
    assert hashlib.sha256(pre_shiny_bytes).hexdigest() == PRE_SHINY_MANIFEST, 'Frozen pre-shiny Magikarp manifest changed'
    pre_shiny = json.loads(pre_shiny_bytes)
    pre_shiny_header = (PRE_SHINY_ROOT / 'BoundGameABI.h').read_bytes()
    assert hashlib.sha256(pre_shiny_header).hexdigest() == PRE_SHINY_HEADER, 'Frozen pre-shiny Magikarp ABI changed'
    assert pre_shiny['integrated_sha256'] == 'fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00'
    assert pre_shiny['contract']['save_state_layout'] == 12
    pre_links_bytes = (PRE_LINKS_ROOT / 'manifest.json').read_bytes()
    assert hashlib.sha256(pre_links_bytes).hexdigest() == PRE_LINKS_MANIFEST, 'Frozen pre-Links menu manifest changed'
    pre_links = json.loads(pre_links_bytes)
    pre_links_header = (PRE_LINKS_ROOT / 'BoundGameABI.h').read_bytes()
    assert hashlib.sha256(pre_links_header).hexdigest() == PRE_LINKS_HEADER, 'Frozen pre-Links menu ABI changed'
    assert pre_links['integrated_sha256'] == 'd7d9ec63064f9ea8dae75fa2ee05817056769f2cc933f4291414267575885583'
    assert pre_links['contract']['save_state_layout'] == 13
    links_menu_bytes = (LINKS_MENU_ROOT / 'manifest.json').read_bytes()
    assert hashlib.sha256(links_menu_bytes).hexdigest() == LINKS_MENU_MANIFEST, 'Frozen native Links menu manifest changed'
    links_menu = json.loads(links_menu_bytes)
    links_menu_header = (LINKS_MENU_ROOT / 'BoundGameABI.h').read_bytes()
    assert hashlib.sha256(links_menu_header).hexdigest() == LINKS_MENU_HEADER, 'Frozen native Links menu ABI changed'
    assert links_menu['integrated_sha256'] == '13d914106810336badd6762258e5bd1b01ab0d8c8044164cdd5d551a227808d8'
    assert links_menu['contract']['save_state_layout'] == 14
    elimination_bytes = (ELIMINATION_ROOT / 'manifest.json').read_bytes()
    assert hashlib.sha256(elimination_bytes).hexdigest() == ELIMINATION_MANIFEST, 'Frozen native elimination manifest changed'
    elimination = json.loads(elimination_bytes)
    elimination_header = (ELIMINATION_ROOT / 'BoundGameABI.h').read_bytes()
    assert hashlib.sha256(elimination_header).hexdigest() == ELIMINATION_HEADER, 'Frozen native elimination ABI changed'
    assert elimination['integrated_sha256'] == 'f7e6e912c4e3694ac4816136bd3d6bfc6889d63f15232077642603f0a2d0cabc'
    assert elimination['contract']['save_state_layout'] == 15
    current = json.loads((ROOT / 'PrototypeConfiguration/integrated-game.json').read_text())
    stack_root = ROOT / 'PrototypeConfiguration/game-profiles/stack-safe-cooperative'
    stack_bytes = (stack_root / 'manifest.json').read_bytes()
    assert hashlib.sha256(stack_bytes).hexdigest() == '6214c13b82dc08f1f2663eaf9da896e8fe7886ae9ff7cbe08e83f440c5141933'
    stack = json.loads(stack_bytes)
    stack_header = (stack_root / 'BoundGameABI.h').read_bytes()
    assert hashlib.sha256(stack_header).hexdigest() == '2162ee0962361594dac67f4c34eda5444c6974e91c3d8379640c7165f85459ab'
    debug_root = ROOT / 'PrototypeConfiguration/game-profiles/debug-native-defaults'
    debug_bytes = (debug_root / 'manifest.json').read_bytes()
    assert hashlib.sha256(debug_bytes).hexdigest() == 'b5b0b3dca499e8dd26d5b119539266d3eec3a248735fec5236ad5ae258a06e17'
    debug = json.loads(debug_bytes)
    debug_header = (debug_root / 'BoundGameABI.h').read_bytes()
    assert hashlib.sha256(debug_header).hexdigest() == 'a12f96766821a1c1159b6a216fe1ea9b5115ae60f96be325e6ac4fdeece638e6'
    friends_root = ROOT / 'PrototypeConfiguration/game-profiles/friends-multiview'
    friends_bytes = (friends_root / 'manifest.json').read_bytes()
    assert hashlib.sha256(friends_bytes).hexdigest() == '5caaf290e8b1c5f13b513048f5435703c1e80539d4ee23830f0f6d884ff2967a'
    friends = json.loads(friends_bytes)
    friends_header = (friends_root / 'BoundGameABI.h').read_bytes()
    assert hashlib.sha256(friends_header).hexdigest() == 'c2d152b8974a2ec6e9c164e928db93526dafabf685510d2475abdc0aae230961'
    # A future ROM import must explicitly review its SHA-1 library identity too.
    assert current['integrated_sha256'] == CURRENT_ROM, 'Review new exact ROM and game ID together'
    def data(value): return 'Data([' + ','.join(map(str, value)) + '])'
    result = ['// Generated by PrototypeTools/generate-bound-game-profiles.py. Do not edit.', 'import Foundation', '', 'enum BoundGameProfiles {']
    for name, manifest, game_id in [('original', old, '5e572144dc845a8b3576b38672447c6507d9f47d'), ('stackSafe', stack, '4b792d8f8b86e1a65b27965bb523fe0a48a20190'), ('debugDefaults', debug, '90a8077cd42c2d8f053e6412250e3276b7c45316'), ('friendsMultiview', friends, '29fe61f1ca2bc49e0f82608e093194021a1db52d'), ('preShinyMagikarp', pre_shiny, '51ebbe0108c0c18bb5bfcbef42ed3d19a4cfd606'), ('preLinksMenu', pre_links, 'eb96749d9ebb8c9e4300885a59b930e94e23eca3'), ('linksMenu', links_menu, 'f0cffbdb710c5b64b3afec815c6e2ce2a9e51f09'), ('nativeElimination', elimination, 'e34215c5eeefc2574821ef4f8e3bc2be6bd91c73'), ('current', current, CURRENT_GAME_ID)]:
        c = manifest['contract']; rules = bytes.fromhex(c['ruleset_id'])
        compatibility = rules + b''.join(c[k].to_bytes(2, 'little') for k in ['abi_major','abi_minor','checkpoint_format','battery_save_version'])
        result += [f'    static let {name} = BoundGameProfile(', f'        romSHA256: "{manifest["integrated_sha256"]}", gameID: "{game_id}",', f'        family: {data(bytes.fromhex(c["game_family_id"]))}, ruleset: {data(rules)},', f'        compatibility: {data(compatibility)}, saveStateLayout: {c["save_state_layout"]},', f'        supportsCooperativeDoubles: {str(c.get("cooperative_doubles", False)).lower()},', '        coreIdentifier: "com.rileytestut.GBADeltaCore", coreStateVersion: 10)']
    result += ['    static let all = [original, stackSafe, debugDefaults, friendsMultiview, preShinyMagikarp, preLinksMenu, linksMenu, nativeElimination, current]', '}', '']
    return {ROOT / 'Delta/Bound/SDK/Generated/BoundGameProfiles.swift': '\n'.join(result).encode(), ROOT / 'Delta/Bound/SharedWorld/BoundOriginalGameABI.h': header, ROOT / 'Delta/Bound/SharedWorld/BoundStackSafeGameABI.h': stack_header, ROOT / 'Delta/Bound/SharedWorld/BoundDebugDefaultsGameABI.h': debug_header, ROOT / 'Delta/Bound/SharedWorld/BoundFriendsMultiviewGameABI.h': friends_header, ROOT / 'Delta/Bound/SharedWorld/BoundPreShinyMagikarpGameABI.h': pre_shiny_header, ROOT / 'Delta/Bound/SharedWorld/BoundPreLinksMenuGameABI.h': pre_links_header, ROOT / 'Delta/Bound/SharedWorld/BoundLinksMenuGameABI.h': links_menu_header, ROOT / 'Delta/Bound/SharedWorld/BoundEliminationGameABI.h': elimination_header}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
    for path, content in generate().items():
        if args.check:
            assert path.read_bytes() == content, f'Stale generated profile: {path}'
        else: path.write_bytes(content)
    print(json.dumps({'verified': True, 'originalBoundRevision': '00bb9324a28d473867d4d5be2c891bf7cefa298a', 'originalHeaderSHA256': OLD_HEADER, 'originalROM': OLD_ROM}))

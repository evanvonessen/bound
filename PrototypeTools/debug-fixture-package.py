#!/usr/bin/env python3
"""Assemble independently validated Paired Start candidates for test-only review.

No simulator, backend, compiled trust registry, or production fixtures are
modified. Run with the approved qa-python and explicit input/output paths.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil

ROM_SHA = '02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79'
FILES = {'checkpoint.state', 'game.sav', 'ewram.bin', 'iwram.bin', 'party.bin', 'soul-local.json'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()


def load_candidate(attempt, role):
    attempt = attempt.resolve(strict=True)
    invocation = json.loads((attempt / 'result.json').read_text())
    assert invocation['status'] == 'native_candidate_passed' and invocation['exit_code'] == 0
    root = attempt / 'candidate'
    report_bytes = (root / 'native-candidate.json').read_bytes()
    report = json.loads(report_bytes)
    audit_bytes = (attempt / 'native-audit.json').read_bytes()
    audit = json.loads(audit_bytes)
    assert report['status'] == 'candidate' and report['pointID'] == '01' and report['role'] == role
    assert report['romSHA256'] == ROM_SHA and all(report['checks'].values())
    assert audit['status'] == 'passed: supplemental copied-RAM native instruction audit'
    assert audit['candidate_report_sha256'] == digest(report_bytes) and audit['native_level_cap'] == 15
    assert set(report['files']) == FILES
    assets = {}
    for name, expected in report['files'].items():
        path = root / name
        assert path.is_file() and not path.is_symlink()
        value = path.read_bytes()
        assert len(value) == expected['bytes'] and digest(value) == expected['sha256'] == audit['files'][name]
        assets[name] = value
    seed, species = (0x12345678, 4) if role == 'controller' else (0x87654321, 7)
    assert report['trainerID'] == seed and report['starterSpecies'] == species and report['starterLevel'] == 5
    assert audit['native_party'][0]['1'] == seed and audit['native_party'][0]['11'] == species
    ledger = json.loads(assets['soul-local.json'])
    assert ledger['run'] == report['run'] and len(ledger['records']) == 1
    assert not ledger['dead'] and not ledger['offering'] and not ledger['ended']
    assert ledger['records'][0]['identity']['trainer'] == seed
    return dict(attempt=attempt, report=report, audit=audit, ledger=ledger, assets=assets,
                report_sha256=digest(report_bytes), audit_sha256=digest(audit_bytes),
                invocation_sha256=digest((attempt / 'result.json').read_bytes()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controller', type=Path, required=True)
    parser.add_argument('--buddy', type=Path, required=True)
    parser.add_argument('--contract', type=Path, required=True)
    parser.add_argument('--source-provenance', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    candidates = {role: load_candidate(getattr(args, role), role) for role in ['controller', 'buddy']}
    a, b = (candidates[role]['report'] for role in ['controller', 'buddy'])
    assert all(a[key] == b[key] for key in ['run', 'settings', 'fixtureVersion', 'gameID', 'coreIdentifier', 'coreStateVersion', 'saveStateLayout'])
    contract_bytes = args.contract.resolve(strict=True).read_bytes()
    contract = json.loads(contract_bytes)
    assert contract['passed'] and contract['integrated_sha256'] == ROM_SHA
    assert contract['contract']['save_state_layout'] == a['saveStateLayout']
    compatibility = {key: a[key] for key in ['romSHA256', 'gameID', 'coreIdentifier', 'coreStateVersion', 'saveStateLayout']}
    compatibility.update(ruleset=contract['contract']['ruleset_id'], protocolVersion=1, saveVersion=1)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    proof = dict(version=1, status='reviewed-test-input candidate; not final certification',
                 pointID='01', romSHA256=ROM_SHA, contractSHA256=digest(contract_bytes),
                 assemblerSHA256=digest(Path(__file__).read_bytes()),
                 sourceProvenanceSHA256=digest(args.source_provenance.resolve(strict=True).read_bytes()),
                 nativeSRAMSaveValidated=False, productionRegistryModified=False,
                 batteryAllFFByRole={role: all(byte == 255 for byte in value['assets']['game.sav']) for role, value in candidates.items()},
                 pending=['Authenticated paired restore/checkpoint/reconnect', 'App-process relaunch',
                          'Authenticated managed-save checkpoint and cold app-process relaunch',
                          'Building transition and early acquisition'],
                 candidates={role: {key: str(value[key]) for key in ['attempt', 'report_sha256', 'audit_sha256', 'invocation_sha256']}
                             for role, value in candidates.items()})
    proof_bytes = encoded(proof)
    (output / 'native-validation.json').write_bytes(proof_bytes)
    reviewed = {}
    for role, candidate in candidates.items():
        report = candidate['report']
        destination = output / 'DEBUGFixtures' / report['fixtureVersion'] / '01' / role
        destination.mkdir(parents=True)
        ledger = copy.deepcopy(candidate['ledger'])
        peer = candidates['buddy' if role == 'controller' else 'controller']['ledger']
        eligible = [record for record in peer['records'] if record['eligible']]
        ledger['partnerAcquisitions'] = sorted({record['slot'] for record in eligible})
        ledger['partnerNames'] = {record['slot']: record['name'] for record in eligible}
        assets = {name: candidate['assets'][name] for name in ['checkpoint.state', 'game.sav']}
        assets['soul-template.json'] = encoded(ledger)
        for name, value in assets.items():
            (destination / name).write_bytes(value)
        certificate = dict(version=1, fixtureVersion=report['fixtureVersion'], pointID='01', role=role,
                           compatibility=compatibility, settings=report['settings'],
                           trainer=dict(id=report['trainerID'], name=report['trainerName'], gender=report['trainerGender']),
                           files={name: dict(bytes=len(value), sha256=digest(value)) for name, value in assets.items()},
                           levelCap=15, preparedTeams='Original native starter, level 5; native Debug New Game setup',
                           nativeValidationDigest=digest(proof_bytes))
        certificate_bytes = encoded(certificate)
        (destination / 'certificate.json').write_bytes(certificate_bytes)
        reviewed['01/' + role] = digest(certificate_bytes)
        shutil.copy2(candidate['attempt'] / 'native-audit.json', output / (role + '-native-audit.json'))
        shutil.copy2(candidate['attempt'] / 'candidate/native-candidate.json', output / (role + '-native-candidate.json'))
        shutil.copy2(candidate['attempt'] / 'result.json', output / (role + '-invocation-result.json'))
    (output / 'reviewed-candidate-digests.json').write_bytes(encoded(reviewed))
    (output / 'README.txt').write_text('Test-only candidate inputs. Product certificate registry remains empty.\n'
        'State-plus-battery restoration passed; all-FF SRAM is NOT a native in-game Save.\n'
        'Peer metadata derives from the other verified party; native identities are never copied.\n'
        'Authenticated paired and remaining native gameplay gates are still required.\n')
    print(json.dumps(dict(path=str(output), reviewedCandidateCertificates=reviewed), indent=2))


if __name__ == '__main__':
    main()

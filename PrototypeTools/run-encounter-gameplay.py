#!/usr/bin/env python3
"""Run native encounter tests on an explicitly owned, freshly prepared simulator.

No account/service configuration, ordinary player data, or shared simulator is
modified. The app and exact bundled ROM are verified before the test invocation.
"""
import argparse, hashlib, json, plistlib, subprocess
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--xctestrun',type=Path,required=True)
p.add_argument('--simulator',required=True)
p.add_argument('--expected-rom-sha256',required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--fixture-only',action='store_true')
p.add_argument('--compatibility-only',action='store_true')
a=p.parse_args()
state=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j'],text=True))
devices=[d for ds in state['devices'].values() for d in ds if d['udid']==a.simulator]
if len(devices)!=1 or not devices[0]['name'].startswith('Bound Encounter Rules QA'):
    p.error('Use only a dedicated Bound Encounter Rules QA simulator')
source=a.xctestrun.resolve(strict=True); products=source.parent
app=products/'Debug-iphonesimulator/Bound.app'; image=app/'multiplayer.gba'
actual=hashlib.sha256(image.read_bytes()).hexdigest()
if actual!=a.expected_rom_sha256 or image.stat().st_size!=33554432:
    p.error('Test app does not contain the exact reviewed paired ROM')
if a.output.exists(): p.error('Preserve previous results; use a new output directory')
a.output.mkdir(parents=True)
selected=['NativeBattleRuntimeTests/testCreateCurrentEncounterGameplayFixture'] if a.fixture_only else [
 'SoulLinkTests','EncounterAllowanceTests','SoulExtrasTests','SoulLinksTests','SoulProbeOwnershipTests','BattleLossTests','CooperativeSoulPairTests',
 'NativeBattleRuntimeTests/testActualEliminationPolicyPublishesAtomicallyAndRejectsOutOfRangeBits',
 'NativeBattleRuntimeTests/testBattleLossGraphicRendersOwnAndPartnerSides',
 'NativeBattleRuntimeTests/testActualLinksMenuUsesDurableCatchOrderAndRestoresField',
 'NativeBattleRuntimeTests/testActualSoulLinkNativeHPAndStateRecovery',
 'NativeBattleRuntimeTests/testActualSoulFrameFencePreservesRAMCompletesPauseAndRejectsReplacement',
 'NativeBattleRuntimeTests/testActualSoulFailedPersistenceRetainsFaintUntilPausedRetryAndExplicitResume',
 'NativeBattleRuntimeTests/testActualSoulEndedRunReleasesOutstandingCriticalFence',
 'NativeBattleRuntimeTests/testSoulRingAcknowledgementRejectsChangedOverflowAndMalformedRings']
if a.compatibility_only:
 selected=['CooperativeDoublesContractTests','ROMMultiplayerContractTests','MultiplayerSavePackageTests','ServerDisconnectSaveTests'] + [
  'MultiRedAdapterTests/'+name for name in ['testFreshDebugGamesUseEasyAndNativeLMenuCanToggleRepelBothWays',
   'testProfilesPreserveExactCompatibilityAndCooperativeCapability','testWorldPacketsUseTheBoundProfileAndRejectCrossRulesets',
   'testSavedRunAdmissionKeepsOriginalIdentityAndRejectsCurrentROM','testActualROMProfilesAndRawStatesRemainSeparate']]
matched=[]
def configure(value):
 if isinstance(value,dict):
  result={k:configure(v) for k,v in value.items()}
  if result.get('BlueprintName')=='BoundIntegrationTests':
   result.setdefault('EnvironmentVariables',{}).update(BOUND_ENCOUNTER_GAMEPLAY='1',BOUND_SOUL_RUNTIME='1')
   result['OnlyTestIdentifiers']=selected; matched.append(True)
  return result
 if isinstance(value,list):return [configure(v) for v in value]
 return value.replace('__TESTROOT__',str(products)) if isinstance(value,str) else value
configuration=configure(plistlib.loads(source.read_bytes()))
if len(matched)!=1: raise RuntimeError('Expected one exact integration-test target')
run=a.output/'encounters.xctestrun';run.write_bytes(plistlib.dumps(configuration))
cmd=['xcodebuild','test-without-building','-xctestrun',str(run),'-destination','platform=iOS Simulator,id='+a.simulator,
 '-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-test-timeouts-enabled','YES',
 '-default-test-execution-time-allowance','180','-maximum-test-execution-time-allowance','240',
 '-resultBundlePath',str(a.output/'tests.xcresult')]
receipt={'simulator':a.simulator,'simulatorName':devices[0]['name'],'romSHA256':actual,'selectors':selected,
 'appExecutableSHA256':hashlib.sha256((app/'Bound').read_bytes()).hexdigest(),'command':cmd,
 'fixtureProvenance':'Native Debug New Game preset, synthetic progression; not a natural playthrough'}
(a.output/'invocation.json').write_text(json.dumps(receipt,indent=2)+'\n')
with (a.output/'test.log').open('wb') as log:
 result=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
receipt['exitCode']=result.returncode
bundle=a.output/'tests.xcresult'
if bundle.exists():
 summary=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle)],capture_output=True,text=True)
 if summary.returncode==0:
  data=json.loads(summary.stdout);(a.output/'summary.json').write_text(json.dumps(data,indent=2)+'\n')
  receipt['summary']=data
(a.output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'exitCode':result.returncode,'output':str(a.output)},indent=2))
raise SystemExit(result.returncode)

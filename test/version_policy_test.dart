import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/version/app_version_gate.dart';

void main() {
  const cached=VersionPolicy(latestBuild:3,minimumBuild:2,
    updateUrl:'https://example.test/app.apk',releaseNotes:'');
  test('build comparison has current optional and mandatory states',(){
    expect(classifyBuild(3,3,2),UpdateState.upToDate);
    expect(classifyBuild(2,3,2),UpdateState.optional);
    expect(classifyBuild(1,3,2),UpdateState.mandatory);
  });
  test('offline is fail-open without confirmed mandatory policy',(){
    expect(classifyOfflineBuild(1,null),UpdateState.upToDate);
    expect(classifyOfflineBuild(2,cached),UpdateState.upToDate);
  });
  test('offline keeps a cached confirmed mandatory block',(){
    expect(classifyOfflineBuild(1,cached),UpdateState.mandatory);
  });
}

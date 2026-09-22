// Hosts app/integration_test/*_test.dart tests as native XCTest cases so
// `flutter drive` (via test_driver/integration_test.dart) can run them on
// iOS — including IntegrationTestWidgetsFlutterBinding.takeScreenshot(),
// which iOS only supports through this native runner, not plain
// `flutter test`. See the `integration_test` package's "iOS Device
// Testing" docs.
@import XCTest;
@import integration_test;

INTEGRATION_TEST_IOS_RUNNER(RunnerTests)

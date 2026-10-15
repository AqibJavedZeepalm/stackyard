import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/sys.dart';
import 'package:stackyard/state/jobs.dart';
import 'package:stackyard/ui/report.dart';

void main() {
  test('a report link names the job and error, hides the home folder and fits in a URL', () {
    final job = Job(const PlannedChange(title: 'Install Flutter 3.27.4'))
      ..status = JobStatus.failed
      ..error = 'fvm exited with 1';
    job.log.addAll([for (var i = 0; i < 2000; i++) 'line $i in ${Sys.home}/fvm/versions/3.27.4', 'The final error']);

    final url = problemReportUrl(job: job, version: '1.2.3');
    final body = url.queryParameters['body']!;
    expect(url.host, 'github.com');
    expect(url.path, '/$repo/issues/new');
    expect(url.queryParameters['title'], 'Failed: Install Flutter 3.27.4');
    expect(body, contains('Stackyard 1.2.3'));
    expect(body, contains('fvm exited with 1'));
    expect(body, contains('The final error'), reason: 'the end of the log is kept');
    expect(body, isNot(contains('line 0 ')), reason: 'the start is cut to fit');
    expect(body, isNot(contains(Sys.home)));
    expect(url.toString().length, lessThanOrEqualTo(7000));
  });

  test('without a job it is a plain report with versions', () {
    final body = problemReportUrl(version: '1.2.3').queryParameters['body']!;
    expect(body, contains('Stackyard 1.2.3'));
    expect(body, isNot(contains('**Log**')));
  });
}

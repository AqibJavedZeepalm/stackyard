import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/sys.dart';
import '../state/jobs.dart';

const repo = 'AqibJavedZeepalm/stackyard';

/// A new GitHub issue with the details filled in, for [job] when something failed.
/// Nothing is sent from here: it opens in the browser, where the person reads it,
/// removes anything private and submits it themselves. Paths in the home folder
/// are shortened to "~" so the user name isn't in it.
Uri problemReportUrl({Job? job, String version = const String.fromEnvironment('APP_VERSION', defaultValue: 'dev')}) {
  String private(String s) => s.replaceAll(Sys.home, '~');
  String body(List<String> log) => [
    '**What happened**',
    '',
    '<!-- What were you doing, and what did you expect? -->',
    '',
    '**Details**',
    '- Stackyard $version',
    '- ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    if (job != null) ...[
      '- Job: ${private(job.title)}',
      '- Error: ${private(job.error ?? 'none')}',
      '',
      '**Log** (the end of it; check for anything private before you submit)',
      '```',
      ...log.map(private),
      '```',
    ],
  ].join('\n');

  // Browsers and GitHub cap URL length: keep the end of the log, where the error is.
  var log = job?.log ?? const <String>[];
  Uri url() => Uri.https('github.com', '/$repo/issues/new', {
    'title': job == null ? '' : 'Failed: ${private(job.title)}',
    'body': body(log),
  });
  while (log.isNotEmpty && url().toString().length > 7000) {
    log = log.sublist(1);
  }
  return url();
}

/// Opens [problemReportUrl] and copies the whole log, in case the link had to shorten it.
Future<void> reportProblem({Job? job}) async {
  if (job != null && job.log.isNotEmpty) await Clipboard.setData(ClipboardData(text: job.log.join('\n').replaceAll(Sys.home, '~')));
  await launchUrl(problemReportUrl(job: job));
}

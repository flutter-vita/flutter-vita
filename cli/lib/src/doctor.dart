// What `flutter-vita doctor` prints, in the shape of `flutter doctor`.
//
// One line per category with a mark for its state, then what was found and,
// for a problem, the fix. The summary shows the problems only; -v shows
// everything. Until 2026-10-28 the doctor printed `ok` or `--` per check, and
// `--` read as a blank, not as a failure.
import 'dart:io';

/// How bad a finding is. The order matters: a category takes its worst.
enum Mark {
  /// Found and usable.
  ok,

  /// Usable, but something is missing that a step later needs (the console).
  warning,

  /// A build cannot run until this is fixed.
  error,
}

/// One line under a category: what was found, or what is wrong and the fix.
class Finding {
  Finding(this.mark, this.text, [this.fix]);

  final Mark mark;
  final String text;

  /// What to do, printed on the lines under [text].
  final String? fix;
}

/// One line of the summary: a part of the toolchain and what was found of it.
class Category {
  Category(this.title);

  final String title;

  /// Printed in brackets after the title: a version, an address.
  String? summary;

  final List<Finding> findings = [];

  void info(String text) => findings.add(Finding(Mark.ok, text));

  void warn(String text, [String? fix]) =>
      findings.add(Finding(Mark.warning, text, fix));

  void fail(String text, [String? fix]) =>
      findings.add(Finding(Mark.error, text, fix));

  Mark get mark => findings.fold(
      Mark.ok, (worst, f) => f.mark.index > worst.index ? f.mark : worst);
}

/// Prints the categories, and returns the exit code: 1 when a build cannot
/// run, 0 otherwise. A missing console is a warning: `build` works without it.
int report(List<Category> categories, {required bool verbose}) {
  final color = stdout.hasTerminal &&
      stdout.supportsAnsiEscapes &&
      !Platform.environment.containsKey('NO_COLOR');
  String paint(Mark mark, String s) {
    if (!color) return s;
    const codes = {Mark.ok: '32', Mark.warning: '33', Mark.error: '31'};
    return '\x1B[${codes[mark]}m$s\x1B[0m';
  }

  const box = {Mark.ok: '[✓]', Mark.warning: '[!]', Mark.error: '[✗]'};
  const bullet = {Mark.ok: '•', Mark.warning: '!', Mark.error: '✗'};

  if (!verbose) {
    stdout.writeln(
        'Doctor summary (to see all details, run flutter-vita doctor -v):');
  }
  for (final c in categories) {
    final title = c.summary == null ? c.title : '${c.title} (${c.summary})';
    stdout.writeln('${paint(c.mark, box[c.mark]!)} $title');
    for (final f in c.findings) {
      if (!verbose && f.mark == Mark.ok) continue;
      stdout.writeln('    ${paint(f.mark, bullet[f.mark]!)} ${f.text}');
      if (f.fix != null) {
        for (final line in f.fix!.split('\n')) {
          stdout.writeln('      $line');
        }
      }
    }
    if (verbose) stdout.writeln();
  }

  final issues = categories.where((c) => c.mark != Mark.ok).length;
  if (!verbose) stdout.writeln();
  if (issues == 0) {
    stdout.writeln('${paint(Mark.ok, '•')} No issues found.');
  } else {
    final worst =
        categories.any((c) => c.mark == Mark.error) ? Mark.error : Mark.warning;
    stdout.writeln('${paint(worst, '!')} Doctor found issues in $issues '
        '${issues == 1 ? 'category' : 'categories'}.');
  }
  return categories.any((c) => c.mark == Mark.error) ? 1 : 0;
}

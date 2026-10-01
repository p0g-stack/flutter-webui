// Copyright 2026 The p0g-stack authors.
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

/// Quotes [word] for a POSIX shell. Every host concatenates `exec`/`spawn`
/// strings unescaped, so every string that reaches the bridge goes through
/// this.
String shellQuote(String word) {
  if (word.isNotEmpty && RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(word)) {
    return word;
  }
  return "'${word.replaceAll("'", r"'\''")}'";
}

/// Quotes and joins [argv] into one shell command line.
String shellCommand(List<String> argv) => argv.map(shellQuote).join(' ');

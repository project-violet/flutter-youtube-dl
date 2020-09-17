/* 
This source code is a part of Project Violet.
Copyright (C) 2020. violet-team.

flutter-youtube-dl is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3, or (at your option)
any later version.

flutter-youtube-dl is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with flutter-youtube-dl; see the file LICENSE.  If not see
<http://www.gnu.org/licenses/>.
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shell/shell.dart';

typedef ExtractProgress = void Function(String file, double progress);

typedef DownloadPath = Future<void> Function(String path);
typedef DownloadProgress = Future<void> Function(double percent);

class YoutubeDLCallback {
  final DownloadPath pathCallback;
  final DownloadProgress progressCallback;

  YoutubeDLCallback({
    this.pathCallback,
    this.progressCallback,
  });
}

class YoutubeDLFormatInfo {
  final int formatCode;
  final String extension;
  final String resolution;
  final String note;
  final String size;
  final bool isVideoOnly;
  final bool isAudioOnly;

  YoutubeDLFormatInfo({
    this.formatCode,
    this.extension,
    this.resolution,
    this.note,
    this.size,
    this.isAudioOnly,
    this.isVideoOnly,
  });
}

// Youtube-DL Wrapper Class
class YoutubeDL {
  static const platform =
      const MethodChannel('flutter_youtube_dl/nativelibdir');
  static Directory nativeDir;

  static Future<Directory> getLibraryDirectory() async {
    if (nativeDir != null) return nativeDir;
    final String result = await platform.invokeMethod('getNativeDir');
    print(await getApplicationSupportDirectory());
    nativeDir = Directory(result);
    return nativeDir;
  }

  static Future<bool> extractRequire() async {
    final dir = await getApplicationSupportDirectory();
    final destinationDir = Directory(dir.path + '/python');
    if (!await destinationDir.exists()) return true;

    if (!await File(join(dir.path, 'python', 'usr', 'bin', 'python3'))
        .exists()) {
      await destinationDir.delete();
      return true;
    }

    return false;
  }

  static Future<void> init(ExtractProgress prog) async {
    final dir = await getApplicationSupportDirectory();
    final destinationDir = Directory(dir.path + '/python');
    if (await destinationDir.exists()) {
      // await destinationDir.delete(recursive: true);
      return;
    }

    final libdir = await getLibraryDirectory();
    final zipFile = File(join(libdir.path, 'libyoutubedl.so'));
    try {
      await ZipFile.extractToDirectory(
        zipFile: zipFile,
        destinationDir: destinationDir,
        onExtracting: (zipEntry, progress) {
          prog(zipEntry.name, progress);
          return ExtractOperation.extract;
        },
      );
    } catch (e) {
      print(e);
    }
  }

  static Future<List<YoutubeDLFormatInfo>> getFormats(String url) async {
    var dir = await getApplicationSupportDirectory();
    var shell = await _createShell();

    var echo = await shell.start('./libpython3', [
      join(dir.path, 'python', 'usr', 'youtube_dl', '__main__.py'),
      '-F',
      url,
      '--cache-dir',
      join(dir.path, 'python', 'usr', 'bin', '.cache'),
    ]);

    var outputs = List<String>();

    await echo.stdout.listen((event) {
      var xx = List<int>.from(event);
      for (var ss in utf8.decode(xx).trim().split('\r'))
        outputs.addAll(ss.trim().split('\n'));
    }).asFuture();

    int starts = 0;
    for (; starts < outputs.length; starts++) {
      if (outputs[starts].trim().startsWith('[info]')) {
        starts += 2;
        break;
      }
    }

    if (starts == outputs.length) return null;

    var result = List<YoutubeDLFormatInfo>();

    for (; starts < outputs.length; starts++) {
      if (outputs[starts].trim() == '1') break;
      var s = outputs[starts]
          .trim()
          .split(' ')
          .where((element) => element != '')
          .toList();

      result.add(YoutubeDLFormatInfo(
        formatCode: int.parse(s[0]),
        extension: s[1],
        resolution:
            !outputs[starts].trim().contains('audio only') ? s[2] : null,
        note: !outputs[starts].trim().contains('audio only') ? s[3] : null,
        size: s.last,
        isAudioOnly: outputs[starts].trim().contains('audio only'),
        isVideoOnly: outputs[starts].trim().contains('video only'),
      ));
    }

    return result;
  }

  static Future<String> requestThumbnail(String url,
      [List<String> options]) async {
    options ??= List<String>();

    var dir = await getApplicationSupportDirectory();
    var shell = await _createShell();

    var pparam = List<String>.from(options);

    pparam.insert(0, url);
    pparam.insert(0, '--get-thumbnail');
    pparam.insert(0, '-q');
    pparam.insert(
        0, join(dir.path, 'python', 'usr', 'youtube_dl', '__main__.py'));
    pparam.add('--cache-dir');
    pparam.add(join(dir.path, 'python', 'usr', 'bin', '.cache'));
    var echo = await shell.start('./libpython3.so', pparam);

    var thumbnail = await echo.stdout.readAsString();
    var err = (await echo.stderr.readAsString()).trim();
    if (err.length != 0) throw Exception(err);

    return thumbnail.trim();
  }

  static Future<void> requestDownload(
      YoutubeDLCallback callback, String url, String path,
      [String format, List<String> options]) async {
    options ??= List<String>();

    var dir = await getApplicationSupportDirectory();
    var shell = await _createShell();

    var pparam = List<String>.from(options);

    if (format != null) {
      pparam.insert(0, format);
      pparam.insert(0, '-f');
    }
    pparam.insert(0, url);
    pparam.insert(0, join(path, "%(extractor)s", "%(title)s.%(ext)s"));
    pparam.insert(0, '-o');
    pparam.insert(
        0, join(dir.path, 'python', 'usr', 'youtube_dl', '__main__.py'));
    pparam.add('--cache-dir');
    pparam.add(join(dir.path, 'python', 'usr', 'bin', '.cache'));
    var echo = await shell.start('./libpython3.so', pparam);

    var prog = RegExp(r'\[download\]\s+(\d+(\.\d)?)%.*?');

    var cannot = false;
    await echo.stdout.listen((event) {
      if (cannot) return;
      var xx = List<int>.from(event);
      for (var ss in utf8.decode(xx).trim().split('\r')) {
        print(ss);
        if (ss.startsWith('[download]')) {
          if (ss.contains('has already been downloaded')) {
            // just keep going
            cannot = true;
            return;
          }

          if (ss.contains('Destination')) {
            callback.pathCallback(ss.split('Destination:').last.trim());
            continue;
          }

          var pp = prog.allMatches(ss);
          callback.progressCallback(double.parse(pp.first[1]));
        }
      }
    }).asFuture();

    var err = (await echo.stderr.readAsString()).trim();
    if (err.length != 0) throw Exception(err);
  }

  static Future<void> requestDownloadWithFFmpeg(
      YoutubeDLCallback callback, String url, String path,
      [String format, List<String> options]) async {
    options ??= List<String>();

    var dir = await getApplicationSupportDirectory();
    var shell = await _createShell();

    var pparam = List<String>.from(options);

    if (format != null) {
      pparam.insert(0, format);
      pparam.insert(0, '-f');
    }
    pparam.insert(0, url);
    pparam.insert(0, join(path, "%(extractor)s", "%(title)s.%(ext)s"));
    pparam.insert(0, '-o');
    pparam.insert(
        0, join(dir.path, 'python', 'usr', 'youtube_dl', '__main__.py'));
    pparam.add('--cache-dir');
    pparam.add(join(dir.path, 'python', 'usr', 'bin', '.cache'));
    var echo = await shell.start('./libpython3.so', pparam);

    var prog = RegExp(r'\[download\]\s+(\d+(\.\d)?)%.*?');

    await echo.stdout.listen((event) {
      var xx = List<int>.from(event);
      for (var ss in utf8.decode(xx).trim().split('\r')) {
        print(ss);
        if (ss.startsWith('[download]')) {
          if (ss.contains('Destination')) {
            callback.pathCallback(ss.split('Destination:').last.trim());
            continue;
          }

          var pp = prog.allMatches(ss);
          callback.progressCallback(double.parse(pp.first[1]));
        }
      }
    }).asFuture();

    print(await echo.stderr.readAsString());
  }

  static Future<Shell> _createShell() async {
    var shell = new Shell();
    var dir = await getApplicationSupportDirectory();
    var bin = await getLibraryDirectory();

    shell.navigate(bin.path);
    shell.environment['LD_LIBRARY_PATH'] =
        join(dir.path, 'python', 'usr', 'lib');
    shell.environment['SSL_CERT_FILE'] =
        join(dir.path, 'python', 'usr', 'etc', 'tls', 'cert.pem');
    shell.environment['PYTHONHOME'] = join(dir.path, 'python', 'usr');

    return shell;
  }
}

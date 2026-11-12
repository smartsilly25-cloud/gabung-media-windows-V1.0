import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'models.dart';

const kFps = 30;
const _swEnc = ['-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '24', '-pix_fmt', 'yuv420p'];

class Info {
  final double dur, w, h;
  Info(this.dur, this.w, this.h);
}

// ===================== WINDOWS: ffmpeg.exe / ffprobe.exe =====================

Process? _proc;
bool _cancelled = false;

/// Cari ffmpeg.exe / ffprobe.exe: folder `ffmpeg\` di samping aplikasi,
/// lalu di samping aplikasi, lalu PATH sistem.
String _bin(String name) {
  final base = File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  for (final p in ['$base${sep}ffmpeg$sep$name.exe', '$base$sep$name.exe']) {
    if (File(p).existsSync()) return p;
  }
  return name; // coba dari PATH
}

Exception _notFound(String name) => Exception(
    '$name.exe tidak ditemukan. Letakkan ffmpeg.exe dan ffprobe.exe di folder "ffmpeg" '
    'di samping aplikasi, atau tambahkan ke PATH Windows.');

Future<Info> _probeWin(String path) async {
  try {
    final r = await Process.run(
      _bin('ffprobe'),
      ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', path],
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    if (r.exitCode != 0) return Info(0, 0, 0);
    final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    final dur = double.tryParse('${(j['format'] as Map?)?['duration']}') ?? 0;
    double w = 0, h = 0;
    for (final st in (j['streams'] as List? ?? const [])) {
      if (st is! Map || st['codec_type'] != 'video') continue;
      w = double.tryParse('${st['width']}') ?? 0;
      h = double.tryParse('${st['height']}') ?? 0;
      var rot = 0.0;
      final sd = st['side_data_list'];
      if (sd is List) {
        for (final e in sd) {
          if (e is Map && e['rotation'] != null) rot = double.tryParse('${e['rotation']}') ?? rot;
        }
      }
      final tags = st['tags'];
      if (tags is Map && tags['rotate'] != null) rot = double.tryParse('${tags['rotate']}') ?? rot;
      if (rot.abs() % 180 == 90) {
        final t = w;
        w = h;
        h = t;
      }
      break;
    }
    return Info(dur, w, h);
  } catch (_) {
    return Info(0, 0, 0);
  }
}

Future<void> _runWin(List<String> args) async {
  if (_cancelled) throw Exception('Dibatalkan');
  final Process p;
  try {
    p = await Process.start(_bin('ffmpeg'), ['-hide_banner', '-nostdin', '-loglevel', 'error', ...args]);
  } on ProcessException {
    throw _notFound('ffmpeg');
  }
  _proc = p;
  p.stdout.drain();
  final err = StringBuffer();
  final errDone = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(err.write);
  final code = await p.exitCode;
  await errDone;
  _proc = null;
  if (_cancelled) throw Exception('Dibatalkan');
  if (code == 0) return;
  final out = err.toString();
  throw Exception(out.length > 700 ? out.substring(out.length - 700) : out);
}

/// Windows: coba encoder GPU (NVIDIA -> Intel -> AMD), kalau tidak ada pakai x264.
Future<List<String>> _pickEncoderWin(Directory dir, int w, int h) async {
  for (final codec in ['h264_nvenc', 'h264_qsv', 'h264_amf']) {
    try {
      final r = await Process.run(_bin('ffmpeg'), [
        '-hide_banner', '-nostdin', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'color=c=black:s=320x240:r=30:d=0.5',
        '-c:v', codec, '-b:v', '2M', '-pix_fmt', 'yuv420p',
        '${dir.path}${Platform.pathSeparator}enc_test.mp4'
      ]);
      if (r.exitCode == 0) {
        final bps = (w * h * kFps * 0.12).round();
        return ['-c:v', codec, '-b:v', '$bps', '-pix_fmt', 'yuv420p'];
      }
    } catch (_) {}
  }
  return _swEnc;
}

/// Simpan hasil ke folder Videos pengguna.
Future<String> _saveWin(String result) async {
  final home = Platform.environment['USERPROFILE'];
  Directory? target;
  if (home != null) target = Directory('$home${Platform.pathSeparator}Videos');
  if (target == null || !target.existsSync()) {
    try {
      target = await getDownloadsDirectory();
    } catch (_) {}
  }
  if (target == null) return result;
  if (!target.existsSync()) target.createSync(recursive: true);
  final dest = '${target.path}${Platform.pathSeparator}${result.split(RegExp(r'[\\/]')).last}';
  File(result).copySync(dest);
  return dest;
}

// ===================== PROBE / RUN (pilih platform) =====================

Future<Info> probeInfo(String path) => _probeWin(path);

Future<double> probeDuration(String path) async => (await probeInfo(path)).dur;

Future<void> cancelRender() async {
  _cancelled = true;
  _proc?.kill();
}

Future<void> _run(List<String> args) => _runWin(args);

Future<List<String>> _pickEncoder(Directory dir, int w, int h) => _pickEncoderWin(dir, w, h);

// ===================== LAYOUT (sama untuk semua platform) =====================

class Cell {
  final double cx, cy, bw, bh;
  Cell(this.cx, this.cy, this.bw, this.bh);
}

/// Mode otomatis: kalau bentuk media mirip bentuk kotak (potongan <= 30%), isi penuh; selain itu tampil utuh.
bool useCover(Opts o, Media m, double cw, double ch, bool multi) {
  if (o.mode == 0) return false;
  if (o.mode == 2) return true;
  if (!multi || m.w <= 0 || m.h <= 0) return false;
  final a = m.w / m.h, c = cw / ch;
  return 1 - min(a, c) / max(a, c) <= 0.3;
}

/// Urutan posisi: kiri-bawah -> kanan -> baris di atasnya (kiri -> kanan).
List<Cell> layout(Fmt f, List<Media> g) {
  final w = f.w.toDouble(), h = f.h.toDouble();
  final n = g.first.multi;
  if (n == 1) {
    final z = g.first.zoom;
    return [Cell(w / 2, h / 2, w * kMargin * z, h * kMargin * z)];
  }
  final grid = bestGrid(f, g);
  final cols = grid[0], rows = grid[1];
  final iw = w * kMarginMulti, ih = h * kMarginMulti;
  final ox = (w - iw) / 2, oy = (h - ih) / 2;
  final cw = (iw - kGap * (cols - 1)) / cols;
  final ch = (ih - kGap * (rows - 1)) / rows;
  return [
    for (var k = 0; k < g.length; k++)
      Cell(ox + (k % cols) * (cw + kGap) + cw / 2,
          oy + (rows - 1 - k ~/ cols) * (ch + kGap) + ch / 2, cw, ch)
  ];
}

Future<String> renderVideo({
  required Fmt fmt,
  required List<Media> items,
  required Bg bg,
  required List<Sound> sounds,
  required double total,
  required bool auto,
  required double manualDur,
  required Opts opts,
  required void Function(String msg, double v) onProgress,
}) async {
  _cancelled = false;
  final cf = scaleFmt(fmt, kQuality[opts.quality]);
  final frames = buildFrames(items);
  final u = auto ? total / items.length : manualDur; // durasi tiap foto/video
  final t = u * items.length;
  final tmp = await getTemporaryDirectory();
  final dir = Directory('${tmp.path}${Platform.pathSeparator}render');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  // Pakai '/' di semua path yang masuk ke ffmpeg / daftar concat (aman di Windows juga).
  final d = dir.path.replaceAll('\\', '/');
  final w = cf.w, h = cf.h;
  String s3(double v) => v.toStringAsFixed(3);

  Future<List<String>> makeSegs(List<String> enc) async {
    final segs = <String>[];
    for (var f = 0; f < frames.length; f++) {
      onProgress('Frame ${f + 1} dari ${frames.length}', f / (frames.length + 1));
      final g = frames[f];
      final dd = u * g.length; // lama frame = jumlah media x durasi per media
      final args = <String>['-y'];
      if (bg.image != null) {
        args.addAll(['-framerate', '$kFps', '-i', bg.image!]);
      } else {
        final c = (bg.color & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
        args.addAll(['-f', 'lavfi', '-t', s3(dd), '-i', 'color=c=0x$c:s=${w}x$h:r=$kFps']);
      }
      for (final m in g) {
        if (m.isVideo) {
          args.addAll(['-i', m.path]);
        } else {
          args.addAll(['-framerate', '$kFps', '-i', m.path]); // foto dibaca sekali
        }
      }
      final fc = StringBuffer();
      fc.write(bg.image != null
          ? '[0:v]scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1,format=yuv420p,'
              'tpad=stop_mode=clone:stop_duration=${s3(dd)},fps=$kFps[bg0];'
          : '[0:v]setsar=1,format=yuv420p[bg0];');
      final cells = layout(cf, g);
      var prev = 'bg0';
      for (var k = 0; k < g.length; k++) {
        final m = g[k], c = cells[k];
        // Media ke-k mulai tampil setelah media sebelumnya selesai (ts),
        // diputar selama u detik, lalu bertahan di frame terakhir sampai frame berakhir.
        final ts = k * u;
        final r = (m.isVideo && m.dur > 0) ? u / m.dur : 1.0;
        final rem = dd - ts - u;
        final fi = min(0.5, u / 4), fo = min(0.5, dd / 8);
        final bw = ev(c.bw), bh = ev(c.bh);
        final fit = useCover(opts, m, c.bw, c.bh, g.length > 1 || g.first.multi > 1)
            ? 'scale=$bw:$bh:force_original_aspect_ratio=increase,crop=$bw:$bh'
            : 'scale=$bw:$bh:force_original_aspect_ratio=decrease:force_divisible_by=2';
        final fades = 'fade=t=in:st=${s3(ts)}:d=${s3(fi)}:alpha=1,fade=t=out:st=${s3(dd - fo)}:d=${s3(fo)}:alpha=1';
        final hold = rem > 0.01 ? 'tpad=stop_mode=clone:stop_duration=${s3(rem)},' : '';
        final chain = m.isVideo
            ? 'setpts=(PTS-STARTPTS)*${r.toStringAsFixed(5)}+${s3(ts)}/TB,fps=$kFps,$fit,setsar=1,format=yuva420p,$hold$fades'
            : '$fit,setsar=1,format=yuva420p,tpad=stop_mode=clone:stop_duration=${s3(dd)},'
                'setpts=PTS-STARTPTS+${s3(ts)}/TB,fps=$kFps,$fades';
        fc.write('[${k + 1}:v]$chain[m$k];');
        fc.write('[$prev][m$k]overlay=x=${c.cx.toStringAsFixed(1)}-w/2:'
            'y=${c.cy.toStringAsFixed(1)}-h/2:eof_action=pass[o$k];');
        prev = 'o$k';
      }
      var graph = fc.toString();
      graph = graph.substring(0, graph.length - 1);
      final out = '$d/seg$f.mp4';
      args.addAll(['-filter_complex', graph, '-map', '[$prev]', '-t', s3(dd), '-r', '$kFps', '-an', ...enc, out]);
      await _run(args);
      segs.add(out);
    }
    return segs;
  }

  onProgress('Menyiapkan encoder…', 0);
  final enc = await _pickEncoder(dir, w, h);
  List<String> segs;
  try {
    segs = await makeSegs(enc);
  } catch (e) {
    if (e.toString().contains('Dibatalkan') || enc.contains('libx264')) rethrow;
    segs = await makeSegs(_swEnc); // encoder hardware gagal -> ulangi dengan x264
  }

  onProgress('Menggabungkan frame…', frames.length / (frames.length + 1));
  File('${dir.path}${Platform.pathSeparator}list.txt')
      .writeAsStringSync(segs.map((p) => "file '$p'").join('\n'));
  final joined = '$d/joined.mp4';
  await _run(['-y', '-f', 'concat', '-safe', '0', '-i', '$d/list.txt', '-c', 'copy', joined]);

  final result = '${tmp.path}${Platform.pathSeparator}Gabung_${DateTime.now().millisecondsSinceEpoch}.mp4';
  final used = sounds.where((s) => min(s.stop, t) - s.start > 0).toList();
  if (used.isEmpty) {
    File(joined).copySync(result);
  } else {
    onProgress('Memasang suara…', 0.97);
    final args = <String>['-y', '-i', joined];
    final fc = StringBuffer();
    for (var k = 0; k < used.length; k++) {
      final s = used[k];
      args.addAll(['-i', s.path]);
      final len = min(s.stop, t) - s.start;
      final ms = (s.start * 1000).round();
      fc.write('[${k + 1}:a]atrim=0:${s3(len)},asetpts=PTS-STARTPTS,adelay=$ms|$ms[a$k];');
    }
    for (var k = 0; k < used.length; k++) {
      fc.write('[a$k]');
    }
    fc.write('amix=inputs=${used.length}:duration=longest:normalize=0[aout]');
    args.addAll(['-filter_complex', fc.toString(), '-map', '0:v', '-map', '[aout]',
      '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-t', s3(t), result]);
    await _run(args);
  }

  final finalPath = await _saveWin(result);
  onProgress('Selesai', 1);
  return finalPath;
}

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parse_dl/theme/window_material.dart';

/// 四档材质 × 明暗的**背景层合成**金标准。
///
/// 真机屏幕抓取在本机不可靠：`CopyFromScreen` 抓到的是屏幕最上层内容
/// （应用没到前台时会抓到别的窗口），而强制切前台又违反用户「不抢前台」
/// 的硬约束。这里改用 `ui.PictureRecorder` 直接画到离屏画布 ——
/// **只验证 Flutter 层负责的那部分**（通透膜），系统材质那层由 DWM 负责、
/// 不在本判据范围内。
///
/// 输出：`build/material_golden/<brightness>_<material>.png`
void main() {
  const outDir = 'build/material_golden';

  /// 画一张「壁纸 + 背景层膜」的合成图，返回 PNG 字节。
  Future<Uint8List> renderComposite(
    WindowMaterial material,
    Brightness brightness,
  ) async {
    const size = 200.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const rect = Rect.fromLTWH(0, 0, size, size);

    // 假壁纸：上暖下冷，与真机壁纸色偏方向一致
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFE8E4DC), Color(0xFFD8DCE2)],
        ).createShader(rect),
    );

    // 背景层只负责「材质之上」那层膜
    final veil = backdropVeilOf(material, brightness);
    if (veil != null) {
      canvas.drawRect(rect, Paint()..color = veil);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  /// 解码 PNG 取中心像素。
  Future<Color> centerPixel(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = frame.image.width;
    final h = frame.image.height;
    final i = ((h ~/ 2) * w + (w ~/ 2)) * 4;
    final b = data!.buffer.asUint8List();
    return Color.fromARGB(b[i + 3], b[i], b[i + 1], b[i + 2]);
  }

  test('四档 × 明暗：背景层合成落盘 + 像素判据', () async {
    Directory(outDir).createSync(recursive: true);
    final results = <String, Color>{};

    for (final brightness in Brightness.values) {
      for (final material in WindowMaterial.values) {
        final png = await renderComposite(material, brightness);
        final tag = '${brightness.name}_${material.id}';
        File('$outDir/$tag.png').writeAsBytesSync(png);
        results[tag] = await centerPixel(png);
      }
    }

    for (final e in results.entries) {
      // ignore: avoid_print
      print('GOLDEN ${e.key} = #${e.value.toARGB32().toRadixString(16).padLeft(8, '0')}');
    }

    // 判据 1（核心）：**四档两两都必须不同**
    //
    // 为什么四档都要不同：真机实测本机深色下 DWM 把 mica / mica-alt /
    // acrylic 渲染成完全相同的背景色 (43,43,43)，只靠 DWM 四档分不出来。
    // 差异全靠 backdropVeilOf，所以这里必须逐对断言。
    for (final brightness in Brightness.values) {
      final b = brightness.name;
      final mats = WindowMaterial.values;
      for (var i = 0; i < mats.length; i++) {
        for (var j = i + 1; j < mats.length; j++) {
          expect(
            results['${b}_${mats[i].id}']!.toARGB32(),
            isNot(equals(results['${b}_${mats[j].id}']!.toARGB32())),
            reason: '$b：${mats[i].id} 与 ${mats[j].id} 的背景层合成相同 —— '
                'DWM 在深色下会把多档渲染成同一色，差异全靠 backdropVeilOf，'
                '这里必须不同',
          );
        }
      }
    }

    // 判据 2：四档的膜都必须非 null（都参与区分）
    for (final brightness in Brightness.values) {
      for (final m in WindowMaterial.values) {
        expect(
          backdropVeilOf(m, brightness),
          isNotNull,
          reason: '${brightness.name} / ${m.id} 没叠膜 —— '
              'DWM 分不出这一档，必须由 Flutter 层补',
        );
      }
    }

    // 判据 3：细亚克力必须比普通亚克力**更暗**（方向与参照物一致）
    for (final brightness in Brightness.values) {
      final b = brightness.name;
      final acrylic = results['${b}_acrylic']!.computeLuminance();
      final thin = results['${b}_acrylic-thin']!.computeLuminance();
      expect(
        thin,
        lessThan(acrylic),
        reason: '$b：细亚克力应比普通亚克力更暗（参照物方向），'
            '实际 acrylic=$acrylic thin=$thin',
      );
    }
  });
}

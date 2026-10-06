import 'package:flutter_test/flutter_test.dart';
import 'package:format_factory/services/compress_calc.dart';

/// 视频压缩/裁剪/分段的纯函数单元测试。
/// 覆盖：时间输入容错解析、有效时长（越界夹取）、按目标体积算视频码率
///（含音频降档与"目标过小"判错）、分段边界（含与裁剪叠加）。
void main() {
  // ---------- parseClockInput ----------

  group('parseClockInput', () {
    test('三种合法写法：时:分:秒 / 分:秒 / 纯秒', () {
      expect(parseClockInput('1:23:45'), 5025);
      expect(parseClockInput('12:34'), 754);
      expect(parseClockInput('90'), 90);
    });

    test('支持小数秒', () {
      expect(parseClockInput('1:30.5'), closeTo(90.5, 0.001));
      expect(parseClockInput('2.5'), closeTo(2.5, 0.001));
    });

    test('容错：首尾空白', () {
      expect(parseClockInput('  12:34  '), 754);
    });

    test('非法输入返回 null', () {
      expect(parseClockInput(''), isNull);
      expect(parseClockInput('abc'), isNull);
      expect(parseClockInput('-5'), isNull);
      expect(parseClockInput('1:-2:3'), isNull);
      expect(parseClockInput('1:2:3:4'), isNull); // 段数太多
      expect(parseClockInput('1:x:3'), isNull);
    });
  });

  // ---------- effectiveDuration ----------

  group('effectiveDuration', () {
    const source = 1920.0; // 32 分钟

    test('没有裁剪输入时返回源时长', () {
      expect(effectiveDuration(sourceDuration: source), source);
      expect(
        effectiveDuration(sourceDuration: source, trimStart: '', trimEnd: ''),
        source,
      );
    });

    test('正常裁剪：end - start', () {
      expect(
        effectiveDuration(sourceDuration: source, trimStart: '10', trimEnd: '70'),
        60,
      );
    });

    test('结束时间越界：夹取到源时长', () {
      expect(
        effectiveDuration(sourceDuration: source, trimStart: '0', trimEnd: '99:00'),
        source,
      );
    });

    test('开始时间越界：整体视为无效，回退源时长', () {
      expect(
        effectiveDuration(sourceDuration: source, trimStart: '99:00', trimEnd: '100:00'),
        source,
      );
    });

    test('结束 <= 开始：裁剪无效，回退源时长', () {
      expect(
        effectiveDuration(sourceDuration: source, trimStart: '60', trimEnd: '30'),
        source,
      );
    });

    test('某一边非法时只忽略那一边', () {
      // 结束非法 → 只裁开头
      expect(
        effectiveDuration(sourceDuration: source, trimStart: '10', trimEnd: 'abc'),
        source - 10,
      );
      // 开始非法 → 只裁结尾
      expect(
        effectiveDuration(sourceDuration: source, trimStart: '', trimEnd: '60'),
        60,
      );
    });

    test('源时长 <= 0 时返回 0', () {
      expect(effectiveDuration(sourceDuration: 0), 0);
    });
  });

  // ---------- calcVideoBitrateKbps ----------

  group('calcVideoBitrateKbps', () {
    // 手算：50 MiB / 300s → 总码率 1398.1 kbps，扣 2% 封装开销与 128k 音频
    final target50MiB = 50 * 1024 * 1024;

    test('正常目标：总码率×0.98 − 音频码率', () {
      final kbps = calcVideoBitrateKbps(
        targetBytes: target50MiB,
        durationSeconds: 300,
      );
      // (52428800*8/300/1000)*0.98 - 128 ≈ 1242
      expect(kbps, 1242);
    });

    test('视频码率不足 300k：音频自动降 64k', () {
      // 目标使得总码率恰为 250 kbps：0.98*250-128=117 (<300) → 改用 64k：181
      final kbps = calcVideoBitrateKbps(
        targetBytes: 3125000, // 250 kbps @ 100s
        durationSeconds: 100,
      );
      expect(kbps, 181);
    });

    test('目标体积太小（视频码率 <100k）：返回 null', () {
      expect(
        calcVideoBitrateKbps(targetBytes: 100 * 1000, durationSeconds: 300),
        isNull,
      );
    });

    test('非法入参：时长/体积 <= 0 返回 null', () {
      expect(calcVideoBitrateKbps(targetBytes: target50MiB, durationSeconds: 0),
          isNull);
      expect(calcVideoBitrateKbps(targetBytes: 0, durationSeconds: 300), isNull);
      expect(calcVideoBitrateKbps(targetBytes: -1, durationSeconds: 300), isNull);
    });

    test('刚好够 300k 时不降档音频', () {
      // 总码率 436 kbps → 0.98*436-128 = 299.28 <300 会降档；
      // 用 437 → 300.26 ≥ 300 保持 128k 音频
      final kbps = calcVideoBitrateKbps(
        targetBytes: 437 * 1000 * 100 ~/ 8,
        durationSeconds: 100,
      );
      expect(kbps, 300);
    });
  });

  // ---------- segmentBounds ----------

  group('segmentBounds', () {
    test('32 分钟视频每段 10 分钟 → 4 段，末段 2 分钟', () {
      final segs = segmentBounds(durationSeconds: 1920, segmentSeconds: 600);
      expect(segs, hasLength(4));
      expect(segs[0].start, 0);
      expect(segs[0].end, 600);
      expect(segs[1].start, 600);
      expect(segs[1].end, 1200);
      expect(segs[2].start, 1200);
      expect(segs[2].end, 1800);
      expect(segs[3].start, 1800);
      expect(segs[3].end, 1920);
    });

    test('段秒大于总时长 → 只有 1 段（等于整体）', () {
      final segs = segmentBounds(durationSeconds: 300, segmentSeconds: 600);
      expect(segs, hasLength(1));
      expect(segs.single.start, 0);
      expect(segs.single.end, 300);
    });

    test('毫秒级溢出不产生超界尾段（remux 产物再分段的核心坑）', () {
      // remux 粗切产物的容器时长是 600.003628 这类毫秒溢出值：
      // ceil(1200.007/600)=3 会凭空多出一段 [1200, 1200.007]，
      // 该段 -ss 超界 + -c copy 产出乱时间戳垃圾文件，必须丢弃
      final segs = segmentBounds(
        durationSeconds: 600.003628 * 2,
        segmentSeconds: 600,
      );
      expect(segs, hasLength(2));
      expect(segs.last.end, closeTo(1200.007, 0.01));
    });

    test('单段毫秒溢出（600.0036/600）→ 1 段而不是 2 段', () {
      final segs =
          segmentBounds(durationSeconds: 600.003628, segmentSeconds: 600);
      expect(segs, hasLength(1));
      expect(segs.single.end, closeTo(600.0036, 0.01));
    });

    test('分段 + 裁剪叠加：先裁再分', () {
      // 裁出 5:00~25:00 共 1200s，每段 600s → 2 段
      final segs = segmentBounds(
        durationSeconds: 1920,
        segmentSeconds: 600,
        trimStart: '5:00',
        trimEnd: '25:00',
      );
      expect(segs, hasLength(2));
      expect(segs[0].start, 300);
      expect(segs[0].end, 900);
      expect(segs[1].start, 900);
      expect(segs[1].end, 1500);
    });

    test('裁剪结束时间越界：夹取到源时长', () {
      final segs = segmentBounds(
        durationSeconds: 1920,
        segmentSeconds: 600,
        trimEnd: '99:00',
      );
      expect(segs, hasLength(4));
      expect(segs.last.end, 1920);
    });

    test('非法输入：段秒 <= 0 / 时长 <= 0 → 空列表', () {
      expect(segmentBounds(durationSeconds: 1920, segmentSeconds: 0), isEmpty);
      expect(segmentBounds(durationSeconds: 1920, segmentSeconds: -5), isEmpty);
      expect(segmentBounds(durationSeconds: 0, segmentSeconds: 600), isEmpty);
    });
  });

  // ---------- defaultTargetMB / compressEffectText ----------

  group('defaultTargetMB', () {
    test('约源体积 40% 向上取整', () {
      // 100 MiB × 40% = 40 MB
      expect(defaultTargetMB(100 * 1024 * 1024), 40);
      // 小文件至少 1 MB
      expect(defaultTargetMB(1024 * 1024 ~/ 2), 1);
    });

    test('读不到体积时返回 null', () {
      expect(defaultTargetMB(0), isNull);
      expect(defaultTargetMB(-1), isNull);
    });
  });

  group('compressEffectText', () {
    test('显示前后体积与降幅百分比', () {
      final text = compressEffectText(100 * 1024 * 1024, 50 * 1024 * 1024);
      expect(text, contains('100 MB'));
      expect(text, contains('50.0 MB'));
      expect(text, contains('−50%'));
    });

    test('输出体积未知时只显示前半', () {
      expect(compressEffectText(1024 * 1024, 0), contains('→ ?'));
      expect(compressEffectText(0, 100), isEmpty);
    });
  });
}

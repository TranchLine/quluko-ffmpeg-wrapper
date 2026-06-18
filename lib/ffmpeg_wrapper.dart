import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';


/// A controller to manage FFmpeg conversion
class FFmpegConversionController {
  FFmpegSession? _session;
  bool _cancelled = false;
  bool get isRunning => _session != null;

  /// Aborts any ongoing conversion
  Future<void> abort() async {
    _cancelled = true;
    final session = _session;
    if (session != null) {
      await FFmpegKit.cancel(session.getSessionId());
      _session = null;
    }
  }
}

/// Video information class
class VideoInfo {
  final int width;
  final int height;
  final double duration;
  final String codec;
  final double aspectRatio;
  final double frameRate;
  final String? audioCodec;

  VideoInfo({
    required this.width,
    required this.height,
    required this.duration,
    required this.codec,
    required this.aspectRatio,
    required this.frameRate,
    this.audioCodec,
  });

  @override
  String toString() {
    return 'VideoInfo(${width}x${height}, ${duration.toStringAsFixed(1)}s, $codec, ${aspectRatio.toStringAsFixed(2)}, ${frameRate.toStringAsFixed(1)}fps)';
  }
}

/// Snapchat video requirements validation result
class SnapchatValidationResult {
  final bool isValid;
  final List<String> issues;
  final VideoInfo? videoInfo;

  SnapchatValidationResult({
    required this.isValid,
    required this.issues,
    this.videoInfo,
  });
}

/// Gets detailed video information using FFprobe
Future<VideoInfo?> getVideoInfo(String videoPath) async {
  try {
    final session = await FFprobeKit.getMediaInformation(videoPath);
    final information = session.getMediaInformation();

    if (information == null) {
      print("⚠️  Could not get media information");
      return null;
    }

    final properties = information.getAllProperties();
    
    // Get video stream info
    final streams = properties?['streams'] as List?;
    if (streams == null || streams.isEmpty) {
      print("⚠️  No streams found");
      return null;
    }

    // Find video stream
    final videoStream = streams.firstWhere(
      (stream) => stream['codec_type'] == 'video',
      orElse: () => null,
    );

    if (videoStream == null) {
      print("⚠️  No video stream found");
      return null;
    }

    // Find audio stream
    final audioStream = streams.firstWhere(
      (stream) => stream['codec_type'] == 'audio',
      orElse: () => null,
    );

    final width = videoStream['width'] ?? 0;
    final height = videoStream['height'] ?? 0;
    final codecName = videoStream['codec_name'] ?? 'unknown';
    
    // Parse duration
    final durationString = information.getDuration();
    final duration = double.tryParse(durationString ?? '0') ?? 0.0;

    // Parse frame rate
    final frameRateStr = videoStream['r_frame_rate'] ?? '30/1';
    final frameRate = _parseFrameRate(frameRateStr);

    final aspectRatio = width > 0 && height > 0 ? width / height : 0.0;
    
    final audioCodec = audioStream?['codec_name'];

    return VideoInfo(
      width: width,
      height: height,
      duration: duration,
      codec: codecName,
      aspectRatio: aspectRatio,
      frameRate: frameRate,
      audioCodec: audioCodec,
    );
  } catch (e) {
    print("❌ Error getting video info: $e");
    return null;
  }
}

/// Parse frame rate string (e.g., "30/1" -> 30.0, "30000/1001" -> 29.97)
double _parseFrameRate(String frameRateStr) {
  try {
    final parts = frameRateStr.split('/');
    if (parts.length == 2) {
      final numerator = double.parse(parts[0]);
      final denominator = double.parse(parts[1]);
      return numerator / denominator;
    }
    return double.tryParse(frameRateStr) ?? 30.0;
  } catch (e) {
    return 30.0;
  }
}

/// Validates if video meets Snapchat Ads requirements
/// 
/// Snapchat Ads Video Requirements:
/// - Codec: H.264
/// - Resolution: Min 720x1280, Recommended 1080x1920 (9:16 aspect ratio)
/// - Duration: 3-180 seconds
/// - Frame Rate: 30 fps recommended
/// - Audio: AAC codec
/// - File Size: Max 1GB
Future<SnapchatValidationResult> validateSnapchatRequirements(String videoPath) async {
  final videoInfo = await getVideoInfo(videoPath);
  
  if (videoInfo == null) {
    return SnapchatValidationResult(
      isValid: false,
      issues: ['Could not read video information'],
    );
  }

  final issues = <String>[];

  // Check codec
  if (videoInfo.codec != 'h264') {
    issues.add("Codec must be H.264, got: ${videoInfo.codec}");
  }

  // Check minimum resolution
  if (videoInfo.width < 720 || videoInfo.height < 1280) {
    issues.add(
      "Resolution too low: ${videoInfo.width}x${videoInfo.height}. Min: 720x1280",
    );
  }

  // Check aspect ratio (9:16 = 0.5625)
  // Allow some tolerance for different aspect ratios
  if (videoInfo.aspectRatio < 0.4 || videoInfo.aspectRatio > 0.7) {
    issues.add(
      "Aspect ratio should be close to 9:16 (vertical), got: ${videoInfo.aspectRatio.toStringAsFixed(2)}",
    );
  }

  // Check duration
  if (videoInfo.duration < 3) {
    issues.add("Duration too short: ${videoInfo.duration.toStringAsFixed(1)}s. Min: 3s");
  } else if (videoInfo.duration > 180) {
    issues.add("Duration too long: ${videoInfo.duration.toStringAsFixed(1)}s. Max: 180s");
  }

  // Check audio codec (if present)
  if (videoInfo.audioCodec != null && videoInfo.audioCodec != 'aac') {
    issues.add("Audio codec should be AAC, got: ${videoInfo.audioCodec}");
  }

  return SnapchatValidationResult(
    isValid: issues.isEmpty,
    issues: issues,
    videoInfo: videoInfo,
  );
}

/// Converts video to meet Snapchat Ads requirements
/// 
/// Output specs:
/// - Codec: H.264
/// - Resolution: 1080x1920 (9:16 aspect ratio)
/// - Frame Rate: 30 fps
/// - Audio: AAC 128kbps
/// - Quality: CRF 23 (good balance between quality and file size)
Future<String?> formatVideoForSnapchat({
  required String inputPath,
  required String outputPath,
  Function(double)? onProgress,
  FFmpegConversionController? controller,
}) async {
  print("🔄 Formatting video for Snapchat...");
  print("   Input: $inputPath");
  print("   Output: $outputPath");

  // Build FFmpeg command for Snapchat specs
  // - Scale to 1080x1920 maintaining aspect ratio
  // - Pad with black bars if needed
  // - H.264 codec with CRF 23
  // - 30 fps
  // - AAC audio at 128kbps
  // - Fast start for web playback
  final command = '-i "$inputPath" '
      '-vf "scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black" '
      '-c:v libx264 '
      '-preset medium '
      '-crf 23 '
      '-r 30 '
      '-pix_fmt yuv420p '
      '-c:a aac '
      '-b:a 128k '
      '-ar 44100 '
      '-movflags +faststart '
      '-y "$outputPath"';

  // Get duration for progress calculation
  Duration? totalDuration;
  try {
    totalDuration = await _getMediaDuration(inputPath);
  } catch (e) {
    print("Could not determine media duration: $e");
  }

  // Use Completer to handle async result
  final completer = Completer<String?>();

  FFmpegKit.executeAsync(
    command,
    (session) async {
      controller?._session = session;
      final returnCode = await session.getReturnCode();
      final success = ReturnCode.isSuccess(returnCode);

      // Final progress update
      if (onProgress != null) {
        onProgress(success ? 1.0 : 0.0);
      }

      if (!success) {
        final output = await session.getOutput();
        print("❌ Snapchat formatting failed. Return code: $returnCode");
        print("Output: $output");
        completer.complete(null);
      } else {
        print("✅ Video formatted for Snapchat successfully");
        completer.complete(outputPath);
      }
    },
    (log) {
      // Log callback
    },
    (statistics) {
      // Statistics callback for live progress
      if (onProgress != null && totalDuration != null) {
        final totalMs = totalDuration.inMilliseconds.toDouble();
        final currentMs = statistics.getTime();

        if (currentMs > 0 && totalMs > 0) {
          final progressValue = (currentMs / totalMs).clamp(0.0, 1.0);
          onProgress(progressValue);
        }
      }
    },
  );

  return completer.future;
}

// Rest of your existing code below...

/// Converts media to: MP4, MOV, MP3, WAV, AAC, FLAC.
Future<bool> convertMedia({
  required String inputPath,
  required String outputPath,
  required String format,
  required String quality,
  Function(double)? onProgress,
  FFmpegConversionController? controller,
}) async {
  final lowerFormat = format.toLowerCase();
  final isAudioFormat = ['mp3', 'wav', 'aac', 'flac'].contains(lowerFormat);
  final isVideoFormat = ['mp4', 'mov'].contains(lowerFormat);

  if (!isAudioFormat && !isVideoFormat) {
    throw UnsupportedError("Unsupported format: $format");
  }

  final inputIsVideo = _isVideoFile(inputPath);

  late String cmd;

  if (!inputIsVideo && isAudioFormat) {
    cmd = _buildAudioCommand(inputPath, outputPath, quality, lowerFormat);
  } else if (inputIsVideo && isAudioFormat) {
    cmd = _buildVideoToAudioCommand(inputPath, outputPath, quality, lowerFormat);
  } else if (inputIsVideo && isVideoFormat) {
    cmd = _buildVideoCommand(inputPath, outputPath, quality);
  } else {
    throw UnsupportedError("Unsupported conversion from this type to $format");
  }

  Duration? totalDuration;
  try {
    totalDuration = await _getMediaDuration(inputPath);
  } catch (e) {
    print("Could not determine media duration: $e");
  }

  final completer = Completer<bool>();

  FFmpegKit.executeAsync(
    cmd,
    (session) async {
      controller?._session = session;
      final returnCode = await session.getReturnCode();
      final success = ReturnCode.isSuccess(returnCode);

      if (onProgress != null) {
        onProgress(success ? 1.0 : 0.0);
      }

      if (!success) {
        final output = await session.getOutput();
        print("FFmpeg conversion failed. Return code: $returnCode");
        print("Output: $output");
      }

      completer.complete(success);
    },
    (log) {},
    (statistics) {
      if (onProgress != null && totalDuration != null) {
        final totalMs = totalDuration.inMilliseconds.toDouble();
        final currentMs = statistics.getTime();

        if (currentMs > 0 && totalMs > 0) {
          final progressValue = (currentMs / totalMs).clamp(0.0, 1.0);
          onProgress(progressValue);
        }
      }
    },
  );

  return completer.future;
}

/// Get the duration of a media file using ffprobe
Future<Duration?> _getMediaDuration(String filePath) async {
  try {
    final session = await FFprobeKit.getMediaInformation(filePath);
    final information = session.getMediaInformation();

    if (information == null) return null;

    final durationString = information.getDuration();
    if (durationString == null || durationString.isEmpty) return null;

    final durationSeconds = double.tryParse(durationString);
    if (durationSeconds == null) return null;

    return Duration(milliseconds: (durationSeconds * 1000).round());
  } catch (e) {
    print("Error getting media duration: $e");
    return null;
  }
}

bool _isVideoFile(String path) {
  final ext = path.split('.').last.toLowerCase();
  return ['mp4', 'mov', 'mkv', 'avi', 'webm'].contains(ext);
}

String _buildVideoCommand(String input, String output, String quality) {
  final crf = _getCRF(quality);
  return '-i "$input" -c:v libx264 -crf $crf -preset ultrafast -c:a aac "$output" -y';
}

String _buildVideoToAudioCommand(String input, String output, String quality, String format) {
  final bitrate = _getAudioBitrate(quality);
  final codec = _getAudioCodec(format);

  if (codec == 'pcm_s16le') {
    return '-i "$input" -vn -c:a $codec "$output" -y';
  } else if (codec == 'flac') {
    return '-i "$input" -vn -c:a $codec -compression_level 5 "$output" -y';
  } else {
    return '-i "$input" -vn -c:a $codec -b:a $bitrate "$output" -y';
  }
}

String _buildAudioCommand(String input, String output, String quality, String format) {
  final bitrate = _getAudioBitrate(quality);
  final codec = _getAudioCodec(format);

  if (codec == 'pcm_s16le') {
    return '-i "$input" -c:a $codec "$output" -y';
  } else if (codec == 'flac') {
    return '-i "$input" -c:a $codec -compression_level 5 "$output" -y';
  } else {
    return '-i "$input" -c:a $codec -b:a $bitrate "$output" -y';
  }
}

String _getAudioCodec(String format) {
  switch (format) {
    case 'mp3':
      return 'libmp3lame';
    case 'aac':
      return 'aac';
    case 'flac':
      return 'flac';
    case 'wav':
      return 'pcm_s16le';
    default:
      throw UnsupportedError("Unsupported audio format: $format");
  }
}

String _getAudioBitrate(String quality) {
  switch (quality.toLowerCase()) {
    case 'low':
      return '96k';
    case 'medium':
      return '192k';
    case 'high':
      return '320k';
    default:
      return '192k';
  }
}

int _getCRF(String quality) {
  switch (quality.toLowerCase()) {
    case 'low':
      return 35;
    case 'medium':
      return 28;
    case 'high':
      return 20;
    default:
      return 28;
  }
}

/// Clips media from a start time to an end time, then exports it with chosen settings.
Future<bool> clipMedia({
  required String inputPath,
  required String outputPath,
  required double startTimeSeconds,
  required double endTimeSeconds,
  required String quality,
  required String format,
  Function(double)? onProgress,
  FFmpegConversionController? controller,
}) async {
  final lowerFormat = format.toLowerCase();
  final isAudioFormat = ['mp3', 'wav', 'aac', 'flac'].contains(lowerFormat);
  final isVideoFormat = ['mp4', 'mov'].contains(lowerFormat);
  final durationSeconds = endTimeSeconds - startTimeSeconds;

  if (durationSeconds <= 0) {
    throw ArgumentError("Clip duration must be greater than zero.");
  }
  if (!isAudioFormat && !isVideoFormat) {
    throw UnsupportedError("Unsupported format: $format");
  }

  final inputIsVideo = _isVideoFile(inputPath);

  late String cmd;

  final targetFormat = isVideoFormat ? lowerFormat : lowerFormat;

  if (inputIsVideo) {
    cmd = _buildVideoClipCommand(
      inputPath,
      outputPath,
      startTimeSeconds,
      durationSeconds,
      quality,
      targetFormat,
    );
  } else if (isAudioFormat) {
    cmd = _buildAudioClipCommand(
      inputPath,
      outputPath,
      startTimeSeconds,
      durationSeconds,
      quality,
      targetFormat,
    );
  } else {
    throw UnsupportedError("Unsupported conversion from this type to $format");
  }

  Duration? totalDuration;
  try {
    totalDuration = Duration(milliseconds: (durationSeconds * 1000).round());
  } catch (e) {
    print("Could not determine media duration: $e");
  }

  final completer = Completer<bool>();

  FFmpegKit.executeAsync(
    cmd,
    (session) async {
      controller?._session = session;
      final returnCode = await session.getReturnCode();
      final success = ReturnCode.isSuccess(returnCode);

      if (onProgress != null) {
        onProgress(success ? 1.0 : 0.0);
      }

      if (!success) {
        final output = await session.getOutput();
        print("FFmpeg clip failed. Return code: $returnCode");
        print("Output: $output");
      }

      completer.complete(success);
    },
    (log) {},
    (statistics) {
      if (onProgress != null && totalDuration != null) {
        final clipTotalMs = totalDuration.inMilliseconds.toDouble();
        final currentMs = statistics.getTime();

        if (currentMs > 0 && clipTotalMs > 0) {
          final progressValue = (currentMs / clipTotalMs).clamp(0.0, 1.0);
          onProgress(progressValue);
        }
      }
    },
  );

  return completer.future;
}

String _buildVideoClipCommand(
  String input,
  String output,
  double start,
  double duration,
  String quality,
  String format,
) {
  final crf = _getCRF(quality);
  if (format == 'mp4' || format == 'mov') {
    return '-i "$input" -ss $start -t $duration -c:v libx264 -crf $crf -preset ultrafast -c:a aac "$output" -y';
  } else {
    final bitrate = _getAudioBitrate(quality);
    final codec = _getAudioCodec(format);
    return '-i "$input" -ss $start -t $duration -vn -c:a $codec -b:a $bitrate "$output" -y';
  }
}

String _buildAudioClipCommand(
  String input,
  String output,
  double start,
  double duration,
  String quality,
  String format,
) {
  final bitrate = _getAudioBitrate(quality);
  final codec = _getAudioCodec(format);

  if (codec == 'pcm_s16le') {
    return '-i "$input" -ss $start -t $duration -c:a $codec "$output" -y';
  } else if (codec == 'flac') {
    return '-i "$input" -ss $start -t $duration -c:a $codec -compression_level 5 "$output" -y';
  } else {
    return '-i "$input" -ss $start -t $duration -c:a $codec -b:a $bitrate "$output" -y';
  }
}

/// Mixes multiple audio tracks in real-time for preview
/// Returns a path to a temporary mixed audio file
Future<String?> mixAudioForPreview({
  required List<Map<String, dynamic>> audioClips,
  required double totalDuration,
  required String tempOutputPath,
}) async {
  if (audioClips.isEmpty) return null;
  
  // Filter out muted clips
  final activeClips = audioClips.where((c) => c['isMuted'] != true).toList();
  if (activeClips.isEmpty) return null;
  
  // Build filter_complex for real-time mixing
  final inputParts = <String>[];
  final filterParts = <String>[];
  
  for (int i = 0; i < activeClips.length; i++) {
    final clip = activeClips[i];
    inputParts.add('-i "${clip['path']}"');
    
    final startTime = (clip['startTime'] as num).toDouble();
    final trimStart = (clip['trimStart'] as num).toDouble();
    final duration = (clip['duration'] as num).toDouble();
    final volume = (clip['volume'] as num).toDouble();
    final delayMs = (startTime * 1000).toInt();
    
    filterParts.add(
      '[${i}:a]atrim=start=$trimStart:duration=$duration,'
      'volume=$volume,'
      'adelay=${delayMs}|${delayMs},'
      'apad=whole_dur=${totalDuration}[a$i]'
    );
  }
  
  final mixInputs = List.generate(activeClips.length, (i) => '[a$i]').join('');
  final amixFilter = '${mixInputs}amix=inputs=${activeClips.length}:duration=longest:dropout_transition=0[out]';
  
  final command = '${inputParts.join(' ')} '
      '-filter_complex "${filterParts.join('; ')}; $amixFilter" '
      '-map "[out]" '
      '-c:a aac -b:a 192k -ar 48000 '
      '-y "$tempOutputPath"';
  
  final session = await FFmpegKit.execute(command);
  final returnCode = await session.getReturnCode();
  
  if (ReturnCode.isSuccess(returnCode)) {
    return tempOutputPath;
  }
  return null;
}

// extract the Video Frapme from the playback

Future<String?> extractVideoFrame({
  required String videoPath,
  required double timeSeconds,
  required String outputPath,
  int width = 480,
}) async {
  final command = '-ss $timeSeconds -i "$videoPath" -vframes 1 -vf "scale=$width:-1" -q:v 2 -y "$outputPath"';
  
  try {
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    
    if (ReturnCode.isSuccess(returnCode)) {
      return outputPath;
    }
    return null;
  } catch (e) {
    print('extractVideoFrame error: $e');
    return null;
  }
}

/// Creates a temporary preview clip starting from a given position
Future<String?> createPreviewClip({
  required String videoPath,
  required double startTime,
  required String outputPath,
  int duration = 5, // 5 second preview
}) async {
  final command = '-ss $startTime -i "$videoPath" '
      '-t $duration '
      '-c:v libx264 -preset ultrafast -crf 28 '
      '-c:a aac -b:a 128k '
     '-movflags +faststart '
      '-y "$outputPath"';
  
  try {
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    if (ReturnCode.isSuccess(returnCode)) {
      return outputPath;
    }
  } catch (e) {
    print('Preview clip error: $e');
  }
  return null;
}


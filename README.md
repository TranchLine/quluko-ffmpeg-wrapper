# Quluko FFmpeg Wrapper

A Dart package wrapping FFmpegKit for media conversion in the Quluko app.

## Usage
```dart
import 'package:postclip_ffmpeg_wrapper/ffmpeg_wrapper.dart';

bool success = await convertMedia(
  inputPath: '.../input.mp4',
  outputPath: '.../output.mp4',
  quality: 'High',
);

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart'; // 💡 新增
// 👇 請補上這兩行 👇
import 'dart:isolate'; // 解決 SendPort 錯誤
import 'package:wakelock_plus/wakelock_plus.dart'; // 解決 WakelockPlus 錯誤
import 'package:audio_session/audio_session.dart' as as_lib; // 💡 新增

const String APP_VERSION = "1.0.44"; // 💡 增加分貝值除錯訊息

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await GlobalManager.init();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: MainAppShell()),
  );
}

enum NoteStatus { downloading, processing, success, failed }

// 💡 新增：這是給系統底層看的前台任務處理器
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {}
  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {}
  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {}
  // 👇 請補上這個方法 👇
  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {}
}

// --- 結構化多語系逐字稿模型 ---
class TranscriptItem {
  String speaker;
  String original;
  String phonetic;
  String translation;
  double startTime;

  TranscriptItem({
    required this.speaker,
    required this.original,
    this.phonetic = '',
    this.translation = '',
    this.startTime = 0.0,
  });

  Map<String, dynamic> toJson() => {
        'speaker': speaker,
        'original': original,
        'phonetic': phonetic,
        'translation': translation,
        'startTime': startTime,
      };

  factory TranscriptItem.fromJson(dynamic json) {
    if (json is String) {
      return TranscriptItem(speaker: 'Unknown', original: json);
    }
    if (json is Map) {
      double parsedTime = 0.0;
      var st = json['startTime'];
      if (st is num) {
        parsedTime = st.toDouble();
      } else if (st is String) {
        parsedTime =
            double.tryParse(st.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
      }
      return TranscriptItem(
        speaker: json['speaker']?.toString() ?? 'Unknown',
        original:
            json['original']?.toString() ?? json['text']?.toString() ?? '',
        phonetic: json['phonetic']?.toString() ?? '',
        translation: json['translation']?.toString() ?? '',
        startTime: parsedTime,
      );
    }
    return TranscriptItem(speaker: 'Unknown', original: '');
  }
}

class TaskItem {
  String description;
  String assignee;
  String dueDate;
  TaskItem(
      {required this.description, this.assignee = '未定', this.dueDate = '未定'});

  Map<String, dynamic> toJson() =>
      {'description': description, 'assignee': assignee, 'dueDate': dueDate};

  factory TaskItem.fromJson(dynamic json) {
    if (json is String) return TaskItem(description: json);
    if (json is Map) {
      return TaskItem(
        description: json['description']?.toString() ?? '',
        assignee: json['assignee']?.toString() ?? '未定',
        dueDate: json['dueDate']?.toString() ?? '未定',
      );
    }
    return TaskItem(description: '');
  }
}

class Section {
  String title;
  double startTime;
  double endTime;
  Section(
      {required this.title, required this.startTime, required this.endTime});

  Map<String, dynamic> toJson() =>
      {'title': title, 'startTime': startTime, 'endTime': endTime};

  factory Section.fromJson(dynamic json) {
    if (json is String) return Section(title: json, startTime: 0, endTime: 0);
    if (json is Map) {
      double parseNum(dynamic val) {
        if (val is num) return val.toDouble();
        if (val is String) {
          return double.tryParse(val.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
        }
        return 0.0;
      }

      return Section(
        title: json['title']?.toString() ?? '未命名段落',
        startTime: parseNum(json['startTime']),
        endTime: parseNum(json['endTime']),
      );
    }
    return Section(title: '未知段落', startTime: 0, endTime: 0);
  }
}

class MeetingNote {
  String id;
  String title;
  DateTime date;
  String audioPath;
  List<String> summary;
  List<TaskItem> tasks;
  List<TranscriptItem> transcript;
  List<Section> sections;
  NoteStatus status;
  bool isPinned;
  String currentStep;

  MeetingNote({
    required this.id,
    required this.title,
    required this.date,
    required this.audioPath,
    this.summary = const [],
    this.tasks = const [],
    this.transcript = const [],
    this.sections = const [],
    this.status = NoteStatus.success,
    this.isPinned = false,
    this.currentStep = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'date': date.toIso8601String(),
        'audioPath': audioPath,
        'summary': summary,
        'tasks': tasks.map((e) => e.toJson()).toList(),
        'transcript': transcript.map((e) => e.toJson()).toList(),
        'sections': sections.map((e) => e.toJson()).toList(),
        'status': status.index,
        'isPinned': isPinned,
        'currentStep': currentStep,
      };

  factory MeetingNote.fromJson(Map<String, dynamic> json) {
    return MeetingNote(
      id: json['id'],
      title: json['title'],
      date: DateTime.parse(json['date']),
      audioPath: json['audioPath'],
      summary: List<String>.from(json['summary'] ?? []),
      tasks: (json['tasks'] as List<dynamic>?)
              ?.map((e) => TaskItem.fromJson(e))
              .toList() ??
          [],
      transcript: (json['transcript'] as List<dynamic>?)
              ?.map((e) => TranscriptItem.fromJson(e))
              .toList() ??
          [],
      sections: (json['sections'] as List<dynamic>?)
              ?.map((e) => Section.fromJson(e))
              .toList() ??
          [],
      status: NoteStatus.values[json['status'] ?? 2],
      isPinned: json['isPinned'] ?? false,
      currentStep: json['currentStep']?.toString() ?? '',
    );
  }
}

void _log(String message) {
  GlobalManager.addLog(message);
}

String _maskKey(String key) {
  if (key.length <= 4) return "****";
  return "...${key.substring(key.length - 4)}";
}

// 使用量追蹤器
class UsageTracker {
  static DateTime? firstUseDate;
  static double groqAudioSeconds = 0;
  static int geminiTextRequests = 0;
  static double geminiAudioSeconds = 0;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    String? dateStr = prefs.getString('usage_first_date');
    firstUseDate = DateTime.tryParse(dateStr!);
    groqAudioSeconds = prefs.getDouble('usage_groq_seconds') ?? 0;
    geminiTextRequests = prefs.getInt('usage_gemini_texts') ?? 0;
    geminiAudioSeconds = prefs.getDouble('usage_gemini_audio_seconds') ?? 0;
  }

  static Future<void> addGroqSeconds(double seconds) async {
    groqAudioSeconds += seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('usage_groq_seconds', groqAudioSeconds);
  }

  static Future<void> addGeminiTextRequest() async {
    geminiTextRequests += 1;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('usage_gemini_texts', geminiTextRequests);
  }

  static Future<void> addGeminiAudioSeconds(double seconds) async {
    geminiAudioSeconds += seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('usage_gemini_audio_seconds', geminiAudioSeconds);
  }
}

// --- Groq API (Whisper V3) ---
class GroqApi {
  // 💡 接收 sttLanguage 參數
  static Future<List<dynamic>> transcribeAudio(String apiKey, File audioFile,
      double audioDurationSeconds, String sttLanguage) async {
    _log("啟動 Groq Whisper V3 引擎進行高精度 STT (語系: $sttLanguage)...");
    var request = http.MultipartRequest('POST',
        Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'));

    request.headers.addAll({'Authorization': 'Bearer $apiKey'});
    request.fields['model'] = 'whisper-large-v3';
    request.fields['response_format'] = 'verbose_json';
    request.fields['temperature'] = '0'; // 嚴格抑制幻覺

    // 💡 根據設定動態調整語系與情境 Prompt
    if (sttLanguage != 'auto') {
      request.fields['language'] = sttLanguage;
    }

    // 💡 修正 1：移除帶有強烈情境的提示詞，避免 Whisper 模型無中生有 (幻覺)
    switch (sttLanguage) {
      case 'zh':
        request.fields['prompt'] = '這是一段真實的會議錄音，請精準聽寫內容。';
        break;
      case 'en':
        request.fields['prompt'] =
            'This is a real meeting recording, please transcribe accurately.';
        break;
      case 'ja':
        request.fields['prompt'] = 'これは実際の会議の録音です。正確に文字起こししてください。';
        break;
      case 'ko':
        request.fields['prompt'] = '실제 회의 녹음입니다. 정확하게 기록해 주세요.';
        break;
      case 'auto':
      default:
        request.fields['prompt'] =
            'Meeting transcription. 會議紀錄。会議の文字起こし。회의 기록.';
        break;
    }

    request.files
        .add(await http.MultipartFile.fromPath('file', audioFile.path));

    var response = await request.send().timeout(const Duration(minutes: 5));
    var responseBody = await response.stream.bytesToString();

    if (response.statusCode == 200) {
      var json = jsonDecode(responseBody);
      _log("✅ Groq STT 辨識完成！成功取得精準時間軸資料。");

      await UsageTracker.addGroqSeconds(audioDurationSeconds);

      return json['segments'] ?? [];
    } else {
      throw Exception('Groq API 錯誤 (${response.statusCode}): $responseBody');
    }
  }
}

class GeminiRestApi {
  static const String _baseUrl = 'https://generativelanguage.googleapis.com';

  static Future<Map<String, dynamic>> uploadFile(
    String apiKey,
    File file,
    String mimeType,
    String displayName,
  ) async {
    int fileSize = await file.length();
    _log(
        '準備上傳音檔 (使用 Key ${_maskKey(apiKey)}): $displayName (${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB)');

    final initUrl = Uri.parse(
        '$_baseUrl/upload/v1beta/files?key=$apiKey&uploadType=resumable');
    final metadata = jsonEncode({
      'file': {'display_name': displayName}
    });

    final initResponse = await http.post(
      initUrl,
      headers: {
        'X-Goog-Upload-Protocol': 'resumable',
        'X-Goog-Upload-Command': 'start',
        'X-Goog-Upload-Header-Content-Length': fileSize.toString(),
        'X-Goog-Upload-Header-Content-Type': mimeType,
        'Content-Type': 'application/json',
      },
      body: metadata,
    );

    if (initResponse.statusCode != 200) {
      throw Exception('Upload init failed: ${initResponse.body}');
    }

    final uploadUrl = initResponse.headers['x-goog-upload-url'];
    if (uploadUrl == null) throw Exception('Failed to retrieve upload URL');

    _log('開始傳送檔案資料...');
    final fileBytes = await file.readAsBytes();
    final uploadResponse = await http.put(
      Uri.parse(uploadUrl),
      headers: {
        'Content-Length': fileSize.toString(),
        'X-Goog-Upload-Offset': '0',
        'X-Goog-Upload-Command': 'upload, finalize',
      },
      body: fileBytes,
    );

    if (uploadResponse.statusCode != 200) {
      throw Exception('File transfer failed: ${uploadResponse.body}');
    }

    final responseData = jsonDecode(uploadResponse.body);
    _log('✅ 上傳成功! File URI: ${responseData['file']['uri']}');
    return responseData['file'];
  }

  static Future<void> waitForFileActive(String apiKey, String fileName) async {
    final url = Uri.parse('$_baseUrl/v1beta/files/$fileName?key=$apiKey');
    int retries = 0;
    while (retries < 60) {
      final response = await http.get(url);
      if (response.statusCode != 200) {
        throw Exception('Check status failed: ${response.body}');
      }
      final state = jsonDecode(response.body)['state'];
      if (state == 'ACTIVE') return;
      if (state == 'FAILED') throw Exception('File processing failed');
      await Future.delayed(const Duration(seconds: 2));
      retries++;
    }
    throw Exception('Timeout waiting for file to become ACTIVE');
  }

  static Future<String> generateContent(
    String lockedApiKey,
    List<String> modelsToTry,
    String prompt,
    String fileUri,
    String mimeType,
    double audioChunkDuration,
  ) async {
    for (String currentModel in modelsToTry) {
      final url = Uri.parse(
          '$_baseUrl/v1beta/models/$currentModel:generateContent?key=$lockedApiKey');

      int retryCount = 0;
      int maxRetries = 4;

      while (retryCount < maxRetries) {
        if (retryCount == 0) _log('發送請求至模型: $currentModel');

        try {
          final response = await http
              .post(
                url,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'contents': [
                    {
                      'parts': [
                        {'text': prompt},
                        {
                          'file_data': {
                            'mime_type': mimeType,
                            'file_uri': fileUri
                          }
                        }
                      ]
                    }
                  ],
                  'generationConfig': {'responseMimeType': 'application/json'}
                }),
              )
              .timeout(const Duration(seconds: 120));

          if (response.statusCode == 429) {
            if (response.body.contains('RESOURCE_EXHAUSTED')) {
              throw Exception("RESOURCE_EXHAUSTED");
            }
            _log("⚠️ 請求過於頻繁 (429)，等待 15 秒...");
            await Future.delayed(const Duration(seconds: 15));
            retryCount++;
            continue;
          }

          if (response.statusCode == 404 || response.statusCode == 400) {
            _log("⚠️ 模型 $currentModel 不可用，切換備援模型...");
            break;
          }

          if (response.statusCode != 200) {
            throw Exception('Generate failed: ${response.body}');
          }

          await UsageTracker.addGeminiAudioSeconds(audioChunkDuration);

          return jsonDecode(response.body)['candidates'][0]['content']['parts']
              [0]['text'];
        } catch (e) {
          if (e.toString().contains("RESOURCE_EXHAUSTED")) {
            rethrow;
          }
          if (retryCount < maxRetries - 1 &&
              !e.toString().contains('Generate failed')) {
            await Future.delayed(const Duration(seconds: 10));
            retryCount++;
            continue;
          } else {
            break;
          }
        }
      }
    }
    throw Exception('所有模型測試失敗');
  }

  static Future<String> generateTextOnly(
      List<String> apiKeys, List<String> modelsToTry, String prompt,
      {Function(String)? onWait}) async {
    for (String currentModel in modelsToTry) {
      for (int k = 0; k < apiKeys.length; k++) {
        String currentKey = apiKeys[k];
        final url = Uri.parse(
            '$_baseUrl/v1beta/models/$currentModel:generateContent?key=$currentKey');

        int retryCount = 0;
        int maxRetries = 3;

        while (retryCount < maxRetries) {
          try {
            final response = await http
                .post(
                  url,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'contents': [
                      {
                        'parts': [
                          {'text': prompt}
                        ]
                      }
                    ],
                    'generationConfig': {'responseMimeType': 'application/json'}
                  }),
                )
                .timeout(const Duration(seconds: 60));

            if (response.statusCode == 429) {
              if (response.body.contains('RESOURCE_EXHAUSTED') ||
                  response.body.contains('Quota exceeded')) {
                _log(
                    "⚠️ Key ${_maskKey(currentKey)} 在 $currentModel 額度已滿，無縫切換下一把 Key...");
                break;
              } else {
                if (onWait != null) onWait("請求過快，短暫休眠 15 秒...");
                await Future.delayed(const Duration(seconds: 15));
                retryCount++;
                continue;
              }
            }

            if (response.statusCode == 404 || response.statusCode == 400) break;

            if (response.statusCode != 200) {
              throw Exception('Generate failed: ${response.body}');
            }

            await UsageTracker.addGeminiTextRequest();

            return jsonDecode(response.body)['candidates'][0]['content']
                ['parts'][0]['text'];
          } catch (e) {
            if (retryCount < maxRetries - 1 &&
                !e.toString().contains('Generate failed')) {
              await Future.delayed(const Duration(seconds: 5));
              retryCount++;
              continue;
            } else {
              break;
            }
          }
        }
      }
    }
    throw Exception('純文字分析：所有 API Key 與模型均已耗盡，請稍後再試。');
  }

  static Future<List<String>> getAvailableModels(String apiKey) async {
    final url = Uri.parse('$_baseUrl/v1beta/models?key=$apiKey');
    _log('正在測試 API Key 狀態...');
    final response = await http.get(url);

    if (response.statusCode != 200) {
      throw Exception('API 測試失敗 (${response.statusCode})');
    }

    final data = jsonDecode(response.body);
    List<String> availableModels = [];

    for (var model in data['models'] ?? []) {
      List<dynamic> methods = model['supportedGenerationMethods'] ?? [];
      if (methods.contains('generateContent')) {
        String name = model['name'] ?? '';
        if (name.startsWith('models/')) name = name.replaceAll('models/', '');
        if (name.contains('gemini') && !name.contains('embedding')) {
          availableModels.add(name);
        }
      }
    }
    _log('✅ API Key 測試成功');
    return availableModels;
  }
}

class GlobalManager {
  static final ValueNotifier<bool> isRecordingNotifier = ValueNotifier(false);
  static final ValueNotifier<List<String>> vocabListNotifier =
      ValueNotifier([]);
  static final ValueNotifier<List<String>> participantListNotifier =
      ValueNotifier([]);
  static final ValueNotifier<List<String>> logsNotifier = ValueNotifier([]);
  static final ValueNotifier<List<MeetingNote>> notesNotifier =
      ValueNotifier([]);

  static Future<List<String>> getApiKeys() async {
    final prefs = await SharedPreferences.getInstance();
    String raw = prefs.getString('api_key') ?? '';
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static Future<String> getGroqApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('groq_api_key') ?? '';
  }

  static String formatTime(double seconds) {
    if (seconds.isNaN || seconds < 0) return "00:00";
    final duration = Duration(milliseconds: (seconds * 1000).toInt());
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static void addLog(String message) async {
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    final newLog = "[$time] [APP] $message";
    final currentLogs = logsNotifier.value;

    final updatedLogs = currentLogs.length > 500
        ? [newLog, ...currentLogs.take(499)]
        : [newLog, ...currentLogs];

    logsNotifier.value = updatedLogs;
    print(newLog);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('app_logs', updatedLogs);
  }

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    vocabListNotifier.value = prefs.getStringList('vocab_list') ?? [];
    participantListNotifier.value =
        prefs.getStringList('participant_list') ?? [];
    logsNotifier.value = prefs.getStringList('app_logs') ?? [];

    _log("APP 啟動 (版本: $APP_VERSION)");

    await UsageTracker.load();
    await loadNotes();
  }

  static Future<void> loadNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(existingJson);
        List<MeetingNote> loaded =
            jsonList.map((e) => MeetingNote.fromJson(e)).toList();
        loaded.sort((a, b) {
          if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
          return b.date.compareTo(a.date);
        });
        notesNotifier.value = loaded;
      } catch (e) {
        print("Load error: $e");
      }
    }
  }

  static Future<void> addVocab(String word) async {
    if (!vocabListNotifier.value.contains(word)) {
      final newList = List<String>.from(vocabListNotifier.value)..add(word);
      vocabListNotifier.value = newList;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('vocab_list', newList);
    }
  }

  static Future<void> removeVocab(String word) async {
    final newList = List<String>.from(vocabListNotifier.value)..remove(word);
    vocabListNotifier.value = newList;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('vocab_list', newList);
  }

  static Future<void> addParticipant(String name) async {
    if (!participantListNotifier.value.contains(name)) {
      final newList = List<String>.from(participantListNotifier.value)
        ..add(name);
      participantListNotifier.value = newList;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('participant_list', newList);
    }
  }

  static Future<void> removeParticipant(String name) async {
    final newList = List<String>.from(participantListNotifier.value)
      ..remove(name);
    participantListNotifier.value = newList;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('participant_list', newList);
  }

  static Future<void> saveNote(MeetingNote note) async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    List<MeetingNote> notes = [];
    if (existingJson != null) {
      try {
        notes = (jsonDecode(existingJson) as List)
            .map((e) => MeetingNote.fromJson(e))
            .toList();
      } catch (e) {}
    }
    int index = notes.indexWhere((n) => n.id == note.id);
    if (index != -1) {
      notes[index] = note;
    } else {
      notes.add(note);
    }
    await prefs.setString(
        'meeting_notes', jsonEncode(notes.map((e) => e.toJson()).toList()));
    await loadNotes();
  }

  static Future<void> deleteNote(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      List<MeetingNote> notes = (jsonDecode(existingJson) as List)
          .map((e) => MeetingNote.fromJson(e))
          .toList();

      final target = notes.firstWhere((n) => n.id == id,
          orElse: () => MeetingNote(
              id: '', title: '', date: DateTime.now(), audioPath: ''));
      if (target.id.isNotEmpty) {
        try {
          final f = await getActualFile(target.audioPath);
          if (await f.exists()) {
            await f.delete();
            _log("已徹底刪除機密音檔: ${f.path}");
          }
        } catch (_) {}
      }

      notes.removeWhere((n) => n.id == id);
      await prefs.setString(
          'meeting_notes', jsonEncode(notes.map((e) => e.toJson()).toList()));
      await loadNotes();
    }
  }

  static Future<File> getActualFile(String savedPath) async {
    File f = File(savedPath);
    if (await f.exists()) return f;
    String fileName = savedPath.split('/').last;
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$fileName');
  }

  static Future<void> analyzeNote(MeetingNote note) async {
    note.status = NoteStatus.processing;
    note.currentStep = "準備讀取音檔...";
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final List<String> apiKeys = await getApiKeys();
    String strategy = prefs.getString('analysis_strategy') ?? 'groq_gemini';
    final String groqKey = prefs.getString('groq_api_key') ?? '';
    // 💡 新增：讀取 STT 語言設定，預設為中文
    final String sttLanguage = prefs.getString('stt_language') ?? 'zh';
    final List<String> vocabList = vocabListNotifier.value;
    final List<String> participantList = participantListNotifier.value;

    try {
      if (apiKeys.isEmpty) throw Exception("請先設定 Gemini API Key");

      List<String> modelsToTry = strategy == 'pro'
          ? ['gemini-pro-latest', 'gemini-2.5-pro']
          : ['gemini-flash-latest', 'gemini-2.5-flash'];

      final audioFile = await getActualFile(note.audioPath);
      if (!await audioFile.exists()) throw Exception("找不到音訊檔案");

      final int fileSize = await audioFile.length();
      final double fileSizeMB = fileSize / (1024 * 1024);
      final bool isOversized = fileSizeMB >= 25.0;

      bool useGeminiFallback = false;

      final tempPlayer = AudioPlayer();
      await tempPlayer.setSource(DeviceFileSource(audioFile.path));
      final duration = await tempPlayer.getDuration();
      await tempPlayer.dispose();
      double totalSeconds = (duration?.inMilliseconds ?? 0) / 1000.0;

      if (strategy == 'groq_gemini') {
        if (isOversized) {
          _log(
              "⚠️ 檔案大小 (${fileSizeMB.toStringAsFixed(1)}MB) 超過 Groq 建議限制。系統將先嘗試上傳，若失敗將無縫降級至原生引擎。");
        }
        if (groqKey.isEmpty) throw Exception("選擇了高精度雙引擎，但未設定 Groq API Key");

        note.currentStep = "Groq STT 引擎分析中...";
        await saveNote(note);

        List<dynamic> whisperSegments = [];
        try {
          whisperSegments = await GroqApi.transcribeAudio(
              groqKey, audioFile, totalSeconds, sttLanguage); // 💡 傳入語言參數
        } catch (e) {
          if (e.toString().contains('413') ||
              e.toString().contains('Too Large') ||
              isOversized) {
            _log("❌ Groq 拒絕處理大型檔案。準備無縫切換至 Gemini 原生引擎...");
            useGeminiFallback = true;
          } else {
            rethrow;
          }
        }

        if (!useGeminiFallback) {
          if (whisperSegments.isEmpty) throw Exception("音檔無內容或辨識失敗");

          List<TranscriptItem> rawTranscript = whisperSegments.map((seg) {
            return TranscriptItem(
              speaker: 'System',
              original: seg['text'],
              startTime: (seg['start'] as num).toDouble(),
            );
          }).toList();

          note.transcript = rawTranscript;
          await saveNote(note);

          List<TranscriptItem> fullTranscript = [];
          StringBuffer currentChunk = StringBuffer();

          int totalSegments = whisperSegments.length;
          // 💡 核心優化：將批次大幅拉高到 150 句，最大化降低 API 呼叫次數
          int batchSize = 150;
          int totalBatches = (totalSegments / batchSize).ceil();
          int chunkCount = 0;

          note.currentStep = "Gemini 講者辨識 (0/$totalBatches)...";
          await saveNote(note);

          for (var i = 0; i < totalSegments; i++) {
            var seg = whisperSegments[i];
            currentChunk.writeln("[${seg['start']}秒] ${seg['text']}");

            if ((i + 1) % batchSize == 0 || i == totalSegments - 1) {
              chunkCount++;

              note.currentStep = "Gemini 講者辨識 ($chunkCount/$totalBatches)...";
              await saveNote(note);

              // 💡 修正 3：加入防呆指令，強迫 Gemini 刪除 STT 產生的無意義幻覺
              // 💡 修改：加強版 Prompt，過濾特定的 Prompt 迴圈幻覺，並強化字典修正
              String textPrompt = """
              以下是外部 STT 引擎產生的純文字逐字稿（帶有精準時間戳）：
              ---
              $currentChunk
              ---
              請扮演極度嚴格的「會議記錄淨化員」，執行以下任務：
              1. 【刪除 Prompt 迴圈幻覺】：若出現「請精準聽寫內容」、「這是一段真實的會議錄音」或類似的重複語句，這是系統產生的雜訊，請務必「整句刪除」，視為靜音。
              2. 【終極幻覺過濾】：YouTube 廣告詞、版權宣告、無意義重複詞 (如 you you you) 一律刪除。
              3. 【強制字典修正】：參考專有詞彙庫：${vocabList.join(', ')}。
                 - 請找出逐字稿中發音相近的錯字，並「強制」修正為詞彙庫中的正確用詞。
                 - 例如：若詞彙庫有「Reflow」，而逐字稿是「回流」或「微波」，請直接改為「Reflow」。
              4. 參考最新與會者名單：${participantList.join(', ')}，判斷說話者。
              5. 若整句話是外文，請翻譯成繁體中文放進 translation 欄位。
              6. 絕對嚴格保留原始括號內的 [秒數]，填入 startTime。
              
              回傳格式：包含 speaker, original, phonetic, translation, startTime 的純 JSON 陣列。若該批次全部都是垃圾幻覺，請回傳 []。
              """;

              try {
                final chunkResponse = await GeminiRestApi.generateTextOnly(
                    apiKeys, modelsToTry, textPrompt, onWait: (msg) async {
                  note.currentStep = "講者辨識 ($chunkCount/$totalBatches) - $msg";
                  await saveNote(note);
                });

                final List<dynamic> parsedList = _parseJsonList(chunkResponse);
                if (parsedList.isNotEmpty) {
                  fullTranscript.addAll(parsedList
                      .map((e) => TranscriptItem.fromJson(e))
                      .toList());
                }

                currentChunk.clear();
                _log("已完成第 $chunkCount/$totalBatches 批次講者辨識。");
              } catch (e) {
                _log("⚠️ 第 $chunkCount 批次講者辨識失敗跳過: $e");
                currentChunk.clear();
                continue;
              }
            }
          }

          // 如果全部被過濾掉或失敗，至少保留 rawTranscript；否則覆蓋成處理好的
          if (fullTranscript.isNotEmpty) {
            note.transcript = fullTranscript;
          }

          note.currentStep = "最終摘要生成中...";
          await saveNote(note);
          await reSummarizeFromTranscript(note);
          return;
        }
      }

      // --- Gemini 原生語音處理模式 ---
      if (strategy != 'groq_gemini' || useGeminiFallback) {
        modelsToTry = strategy == 'pro'
            ? ['gemini-pro-latest', 'gemini-2.5-pro']
            : ['gemini-flash-latest', 'gemini-2.5-flash'];

        int currentKeyIndex = 0;
        String lockedKey = apiKeys[currentKeyIndex];

        int chunkSize = strategy == 'pro' ? 120 : 300;

        if (totalSeconds <= 0) totalSeconds = chunkSize * 36.0;
        int maxChunks = (totalSeconds / chunkSize).ceil();
        if (maxChunks == 0) maxChunks = 1;

        note.currentStep = "上傳大型音訊檔案中...";
        await saveNote(note);

        var fileInfo = await GeminiRestApi.uploadFile(
            lockedKey, audioFile, 'audio/mp4', note.title);
        String fileUri = fileInfo['uri'];
        await GeminiRestApi.waitForFileActive(
            lockedKey, fileInfo['name'].split('/').last);

        note.currentStep = "AI 正在分析會議摘要...";
        await saveNote(note);

        String overviewPrompt = """
        專有詞彙庫：${vocabList.join(', ')}。預設與會者名單：${participantList.join(', ')}。
        請直接回傳純 JSON 格式，包含: title, summary, tasks, sections。
        sections 的 startTime 與 endTime 必須是「絕對秒數」（純數字）。
        """;

        try {
          final overviewResponseText = await GeminiRestApi.generateContent(
              lockedKey,
              modelsToTry,
              overviewPrompt,
              fileUri,
              'audio/mp4',
              totalSeconds);
          final overviewJson = _parseJson(overviewResponseText);
          note.title = overviewJson['title']?.toString() ?? note.title;
          var rawSummary = overviewJson['summary'];
          note.summary = rawSummary is List
              ? rawSummary.map((e) => e.toString()).toList()
              : ["摘要生成失敗"];
          note.tasks = (overviewJson['tasks'] as List<dynamic>?)
                  ?.map((e) => TaskItem.fromJson(e))
                  .toList() ??
              [];
          note.sections = (overviewJson['sections'] as List<dynamic>?)
                  ?.map((e) => Section.fromJson(e))
                  .toList() ??
              [];
        } catch (e) {
          _log("摘要產生遇到問題: $e，將繼續嘗試逐字稿聽打。");
        }

        List<TranscriptItem> fullTranscript = [];
        int emptyCount = 0;

        for (int i = 0; i < maxChunks; i++) {
          note.currentStep = "原生語音聽打 (${i + 1}/$maxChunks)...";
          await saveNote(note);
          _log(note.currentStep);

          double chunkStart = (i * chunkSize).toDouble();
          double chunkEnd = ((i + 1) * chunkSize).toDouble();
          double thisChunkDuration = chunkEnd > totalSeconds
              ? (totalSeconds - chunkStart)
              : chunkSize.toDouble();

          // 💡 修正 2：加入防禦性 Prompt，強制 Gemini 遵守時間軸，且遇到靜音必須捨棄
          String transcriptPrompt = """
          請扮演極度專業的「多語系逐字稿聽打員」。這是一份長音檔，請你【嚴格且只針對】第 $chunkStart 秒 到第 $chunkEnd 秒的音訊片段提供逐字稿。
         
          【極度重要限制】：
          1. 絕對不可從 0 秒開始聽打！你必須精準從第 $chunkStart 秒的聲音開始。不要重複前面的內容！
          2. 如果這個片段 ($chunkStart 秒 ~ $chunkEnd 秒) 裡面是「靜音」、「無人說話」或「純環境雜音」，請直接回傳空陣列 []，絕對不要憑空捏造對話！
          3. 【強制短句斷點】：單一句子長度超過 10 秒必須斷開。
          
          請回傳純 JSON 陣列，包含 speaker, original, startTime。
          """;

          bool chunkSuccess = false;
          while (!chunkSuccess) {
            try {
              final chunkResponseText = await GeminiRestApi.generateContent(
                  lockedKey,
                  modelsToTry,
                  transcriptPrompt,
                  fileUri,
                  'audio/mp4',
                  thisChunkDuration);
              final List<dynamic> chunkList = _parseJsonList(chunkResponseText);

              if (chunkList.isEmpty) {
                emptyCount++;
                if (emptyCount >= 2) break;
              } else {
                emptyCount = 0;
                var newItems =
                    chunkList.map((e) => TranscriptItem.fromJson(e)).toList();
                newItems.removeWhere((item) => item.startTime > totalSeconds);
                fullTranscript.addAll(newItems);
              }
              chunkSuccess = true;
            } catch (e) {
              if (e.toString().contains("RESOURCE_EXHAUSTED")) {
                currentKeyIndex++;
                if (currentKeyIndex >= apiKeys.length) {
                  throw Exception("所有 API Key 均已耗盡！");
                }

                lockedKey = apiKeys[currentKeyIndex];
                _log("🔄 額度滿載！無縫切換 Key ${_maskKey(lockedKey)}，正在重新上傳音檔...");

                note.currentStep = "額度切換，重傳音檔中...";
                await saveNote(note);

                fileInfo = await GeminiRestApi.uploadFile(
                    lockedKey, audioFile, 'audio/mp4', note.title);
                fileUri = fileInfo['uri'];
                await GeminiRestApi.waitForFileActive(
                    lockedKey, fileInfo['name'].split('/').last);

                note.currentStep = "原生語音聽打 (${i + 1}/$maxChunks)...";
                await saveNote(note);
              } else {
                _log("分段 $i 最終分析失敗: $e");
                chunkSuccess = true;
              }
            }
          }
        }

        note.transcript = fullTranscript;
        note.status = NoteStatus.success;
        note.currentStep = '';
        await saveNote(note);
        _log("分析完成！");
      }
    } catch (e) {
      _log("分析流程錯誤: $e");
      note.status = NoteStatus.failed;
      note.summary = ["分析失敗: $e"];
      note.currentStep = '';
      await saveNote(note);
    }
  }

  static Future<void> reCalibrateTranscript(MeetingNote note) async {
    note.status = NoteStatus.processing;
    note.currentStep = "準備校正逐字稿...";
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final List<String> apiKeys = await getApiKeys();
    final String strategy =
        prefs.getString('analysis_strategy') ?? 'groq_gemini';
    final List<String> vocabList = vocabListNotifier.value;
    final List<String> participantList = participantListNotifier.value;

    try {
      if (apiKeys.isEmpty) throw Exception("請先設定 API Key");
      if (note.transcript.isEmpty) throw Exception("沒有可用的逐字稿，請選擇「徹底語音重聽」。");

      List<String> modelsToTry = strategy == 'pro'
          ? ['gemini-pro-latest', 'gemini-2.5-pro']
          : ['gemini-flash-latest', 'gemini-2.5-flash'];

      List<TranscriptItem> calibratedTranscript = [];

      int totalItems = note.transcript.length;
      int batchSize = 150;
      int totalBatches = (totalItems / batchSize).ceil();

      for (int i = 0; i < totalBatches; i++) {
        int startIdx = i * batchSize;
        int endIdx = min((i + 1) * batchSize, totalItems);
        var batchItems = note.transcript.sublist(startIdx, endIdx);

        note.currentStep = "AI 正在校正錯字與講者 (${i + 1}/$totalBatches)...";
        await saveNote(note);

        StringBuffer currentChunk = StringBuffer();
        for (var item in batchItems) {
          currentChunk.writeln(
              "[${item.startTime}秒] ${item.speaker}: ${item.original}");
        }

        String textPrompt = """
        以下是現有的逐字稿（帶有精準時間戳）：
        ---
        $currentChunk
        ---
        請扮演極度嚴格的「會議記錄淨化員」，執行以下「校正」任務：
        1. 【終極幻覺過濾】：請掃描並直接「整句刪除」以下 STT 幻覺垃圾訊息，絕對不要回傳：
           - 任何包含訂閱、按讚、轉發、打賞等 YouTube 廣告詞。
           - 無意義的連續重複單字 (如 you you you)。
           - 字幕組或版權宣告。
        2. 參考最新專有詞彙庫：${vocabList.join(', ')}。修正錯字。
        3. 參考最新與會者名單：${participantList.join(', ')}。重新精準判斷說話者是誰。
        4. 【極度重要】：絕對嚴格保留原始括號內的 [秒數]，並填入 startTime 欄位，不可竄改任何時間戳！
        
        請回傳格式：包含 speaker, original, phonetic, translation, startTime 的純 JSON 陣列。若全段皆為幻覺，回傳 []。
        """;

        try {
          final chunkResponse = await GeminiRestApi.generateTextOnly(
              apiKeys, modelsToTry, textPrompt, onWait: (msg) async {
            note.currentStep = "校正進度 (${i + 1}/$totalBatches) - $msg";
            await saveNote(note);
          });

          final List<dynamic> parsedList = _parseJsonList(chunkResponse);
          if (parsedList.isNotEmpty) {
            calibratedTranscript.addAll(
                parsedList.map((e) => TranscriptItem.fromJson(e)).toList());
          }
          _log("已完成第 ${i + 1}/$totalBatches 批次文字校正。");
        } catch (e) {
          _log("⚠️ 第 ${i + 1} 批次校正失敗，已為您保留該段的原始內容: $e");
          calibratedTranscript.addAll(batchItems);
        }
      }

      note.transcript = calibratedTranscript;
      await saveNote(note);

      note.currentStep = "文字校正完畢，正在重整最終摘要...";
      await saveNote(note);
      await reSummarizeFromTranscript(note);
    } catch (e) {
      _log("校正流程發生嚴重錯誤: $e");
      note.status = NoteStatus.failed;
      note.summary.insert(0, "校正失敗: $e");
      note.currentStep = '';
      await saveNote(note);
    }
  }

  static Future<void> reSummarizeFromTranscript(MeetingNote note) async {
    note.status = NoteStatus.processing;
    note.currentStep = "基於最新逐字稿整理摘要...";
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final List<String> apiKeys = await getApiKeys();
    final String strategy = prefs.getString('analysis_strategy') ?? 'flash';

    try {
      if (apiKeys.isEmpty) throw Exception("請先設定 API Key");

      List<String> modelsToTry = strategy == 'pro'
          ? ['gemini-pro-latest', 'gemini-2.5-pro']
          : ['gemini-flash-latest', 'gemini-2.5-flash'];

      final audioFile = await getActualFile(note.audioPath);
      final tempPlayer = AudioPlayer();
      await tempPlayer.setSource(DeviceFileSource(audioFile.path));
      final duration = await tempPlayer.getDuration();
      await tempPlayer.dispose();
      double totalSeconds = (duration?.inMilliseconds ?? 0) / 1000.0;
      if (totalSeconds <= 0) totalSeconds = 120.0 * 36;

      StringBuffer sb = StringBuffer();
      for (var t in note.transcript) {
        sb.writeln("[${t.startTime}秒] ${t.speaker}: ${t.original}");
      }
      String transcriptText = sb.toString();

      if (transcriptText.trim().isEmpty) throw Exception("逐字稿為空，無法摘要");

      // 💡 修正 4：防止摘要腦補不存在的人事物
      String prompt = """
      以下是會議逐字稿：
      ---
      $transcriptText
      ---
      請根據上方文字，重新整理會議摘要與任務。
      【嚴格限制】：
      1. 內容必須 100% 來自上方文字，絕對禁止腦補任何未在逐字稿中出現的「人名」或「事項」！
      2. 待辦事項如果沒有明確負責人，請填寫「未定」。
      3. sections 的 startTime 與 endTime 必須填寫「純數字的秒數」，絕不可用 MM:SS！
      
      請回傳包含 title, summary, tasks, sections 的純 JSON 格式。
      """;

      final responseText =
          await GeminiRestApi.generateTextOnly(apiKeys, modelsToTry, prompt);
      final overviewJson = _parseJson(responseText);

      note.title = overviewJson['title']?.toString() ?? note.title;
      var rawSummary = overviewJson['summary'];
      note.summary = rawSummary is List
          ? rawSummary.map((e) => e.toString()).toList()
          : ["無法生成摘要"];
      note.tasks = (overviewJson['tasks'] as List<dynamic>?)
              ?.map((e) => TaskItem.fromJson(e))
              .toList() ??
          [];

      note.sections = (overviewJson['sections'] as List<dynamic>?)
              ?.map((e) => Section.fromJson(e))
              .toList() ??
          [];

      for (var sec in note.sections) {
        if (sec.endTime > totalSeconds) sec.endTime = totalSeconds;
        if (sec.startTime > totalSeconds) sec.startTime = totalSeconds - 1;
      }

      note.status = NoteStatus.success;
      note.currentStep = '';
      await saveNote(note);
      _log("基於逐字稿重分析完成！");
    } catch (e) {
      _log("重分析失敗: $e");
      note.status = NoteStatus.failed;
      note.summary = ["重新摘要失敗: $e"];
      note.currentStep = '';
      await saveNote(note);
    }
  }

  static Map<String, dynamic> _parseJson(String? text) {
    if (text == null) return {};
    try {
      String cleanText = text.trim();
      if (cleanText.startsWith('```json')) {
        cleanText = cleanText.substring(7);
      } else if (cleanText.startsWith('```')) {
        cleanText = cleanText.substring(3);
      }
      if (cleanText.endsWith('```')) {
        cleanText = cleanText.substring(0, cleanText.length - 3);
      }
      final result = jsonDecode(cleanText.trim());
      if (result is Map) return result as Map<String, dynamic>;
      return {};
    } catch (e) {
      return {};
    }
  }

  static List<dynamic> _parseJsonList(String? text) {
    if (text == null) return [];
    try {
      String cleanText = text.trim();
      if (cleanText.startsWith('```json')) {
        cleanText = cleanText.substring(7);
      } else if (cleanText.startsWith('```')) {
        cleanText = cleanText.substring(3);
      }
      if (cleanText.endsWith('```')) {
        cleanText = cleanText.substring(0, cleanText.length - 3);
      }
      final result = jsonDecode(cleanText.trim());
      if (result is List) return result;
      if (result is Map &&
          result.containsKey('transcript') &&
          result['transcript'] is List) {
        return result['transcript'];
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}

class MainAppShell extends StatefulWidget {
  const MainAppShell({super.key});
  @override
  State<MainAppShell> createState() => _MainAppShellState();
}

// 💡 修改：加上 with WidgetsBindingObserver 讓 APP 可以感知自己是在前景還是背景
class _MainAppShellState extends State<MainAppShell>
    with WidgetsBindingObserver {
  int currentIndex = 0;
  final AudioRecorder audioRecorder = AudioRecorder();
  final Stopwatch stopwatch = Stopwatch();
  Timer? timer;
  String timerText = "00:00";
  int recordingPart = 1;
  DateTime? recordingSessionStartTime;

  // 👇 💡 新增這兩個變數，用來控制中斷與恢復邏輯 👇
  bool _isSystemInterrupted = false; // 💡 新增：用來追蹤是否正在等待資源釋放
  bool _isRecovering = false;
  int _deadMicCounter = 0; // 💡 新增：用來追蹤連續空跑(絕對靜音)的秒數
  // 💡 新增：追蹤 APP 是否在畫面上
  bool _isAppInForeground = true;

  final List<Widget> pages = [const HomePage(), const SettingsPage()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 💡 新增：註冊觀察者
    _initForegroundTask(); // 💡 新增：初始化背景任務設定
  }

  // 💡 新增這個方法：設定前台通知的外觀與行為
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'recording_channel',
        channelName: '會議錄音背景服務',
        channelDescription: '保持麥克風在背景持續錄音不中斷',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 💡 新增：移除觀察者
    timer?.cancel();
    audioRecorder.dispose();
    super.dispose();
  }

  // 💡 新增：當 APP 被退到背景、或切換到其他 APP 時，系統會自動呼叫這個方法
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      if (state == AppLifecycleState.resumed) {
        _isAppInForeground = true; // 回到 APP 畫面
        GlobalManager.addLog("📱 [生命週期] APP 回到前景 (Resumed)"); // 💡 新增追蹤
      } else {
        _isAppInForeground = false; // 離開 APP (包含退到桌面、鎖屏、上拉選單等)
        GlobalManager.addLog("📱 [生命週期] APP 進入背景 ($state)"); // 💡 新增追蹤
      }
    });
  }

  void toggleRecording() async {
    if (GlobalManager.isRecordingNotifier.value) {
      await stopAndAnalyze(manualStop: true);
    } else {
      recordingPart = 1;
      recordingSessionStartTime = DateTime.now();
      await startRecording();
    }
  }

  Future<void> startRecording() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.microphone,
      Permission.notification, // 💡 新增這行：要求通知權限，確保前台服務能成功掛起
    ].request();

    if (statuses[Permission.microphone]!.isGranted) {
      // 💡 新增：啟動極致背景前台服務！這會在手機通知欄掛起一個無法被清除的通知，死守麥克風
      if (await FlutterForegroundTask.isRunningService == false) {
        await FlutterForegroundTask.startService(
          notificationTitle: '會議錄音中',
          notificationText: 'APP 正在背景安全地為您錄製會議...',
          callback: startCallback,
        );
      }
      // 👇👇👇 💡 新增：設定 AudioSession，允許與其他 App (如 YouTube) 混音 👇👇👇
      final session = await as_lib.AudioSession.instance;
      await session.configure(as_lib.AudioSessionConfiguration(
        avAudioSessionCategory: as_lib.AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            as_lib.AVAudioSessionCategoryOptions.allowBluetooth |
                as_lib.AVAudioSessionCategoryOptions.defaultToSpeaker |
                as_lib.AVAudioSessionCategoryOptions
                    .mixWithOthers, // 👈 關鍵：允許混音，不被 YT 中斷
        androidAudioAttributes: as_lib.AndroidAudioAttributes(
          contentType: as_lib.AndroidAudioContentType.speech,
          flags: as_lib.AndroidAudioFlags.none,
          usage: as_lib.AndroidAudioUsage
              .media, // 💡 修正1：改為 media，避免系統誤以為在講電話而阻擋 YouTube
        ),
        androidWillPauseWhenDucked: false,
      ));

      await session
          .setActive(true); // 💡 修正3：必須呼叫這行！iOS 才會套用混音，Android 則會默默套用不搶焦點的設定

      final dir = await getApplicationDocumentsDirectory();
      final fileName =
          "rec_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}_p$recordingPart.m4a";
      final path = '${dir.path}/$fileName';

      _isSystemInterrupted = false; // 💡 新增：每次手動開始前，重置中斷狀態
      _deadMicCounter = 0; // 💡 每次手動開始前，重置計數器

      await audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: false, // 💡 修正4：關閉自動增益，讓麥克風回歸最純粹的收音模式，不再與喇叭互斥
          echoCancel: false,
          noiseSuppress: false,
        ),
        path: path,
      );

      stopwatch.reset();
      stopwatch.start();

      // 👇👇👇 將原本的 timer 整個替換成這個 👇👇👇
      timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted) return;

        if (_isRecovering) return; // 正在嘗試恢復中，跳過此秒

        bool isStillRecording = await audioRecorder.isRecording();
        bool isMicDead = false;

        // 💡 監控「空跑/被靜音」：檢查麥克風分貝是否為絕對死寂 (<= -150dB)
        if (isStillRecording && !_isSystemInterrupted) {
          try {
            final amp = await audioRecorder.getAmplitude();
            // 💡 新增：每 2 秒印出一次除錯資訊，避免洗版，同時保留高解析度監控
            if (timer.tick % 2 == 0) {
              GlobalManager.addLog(
                  "📊 [監控] 前景: $_isAppInForeground | 分貝: ${amp.current.toStringAsFixed(2)} dB | 空跑: $_deadMicCounter 秒");
            }

            // 💡 調整：我們先將閾值設為 -100.0，後續可依據日誌測出的真實極限值再做微調
            if (amp.current <= -100.0) {
              _deadMicCounter++;
            } else {
              _deadMicCounter = 0;
            }

            // 💡 關鍵修改：連續 3 秒死寂 且 APP 在背景，才觸發救援機制！
            if (_deadMicCounter >= 3 && !_isAppInForeground) {
              isMicDead = true;
            }
          } catch (_) {}
        }

        // 💡 系統中斷觸發區 (真的沒在錄，或者陷入空跑被靜音狀態)
        if ((!isStillRecording || isMicDead) &&
            GlobalManager.isRecordingNotifier.value) {
          if (!_isSystemInterrupted) {
            _isSystemInterrupted = true;
            _deadMicCounter = 0; // 重置計數器
            stopwatch.stop();
            GlobalManager.addLog("⚠️ 偵測到麥克風遭系統強制收回(空跑)，保存進度並進入等待模式...");

            // 💡 智能通知：引導使用者點擊回 APP 恢復
            FlutterForegroundTask.updateService(
              notificationTitle: '⚠️ 錄音被系統暫停',
              notificationText: '請點擊回到 APP 即可自動恢復錄音',
            );

            try {
              final path = await audioRecorder.stop();
              // 如果錄段大於 4 秒才保存 (扣掉剛才偵測空跑的 3 秒)
              if (path != null && stopwatch.elapsed.inSeconds >= 4) {
                String title = "會議錄音 Part $recordingPart (被中斷)";
                createNewNoteAndAnalyze(path, title, date: DateTime.now());
              } else if (path != null) {
                File(path).delete().catchError((_) {});
              }
            } catch (e) {
              GlobalManager.addLog("保存舊檔發生異常: $e");
            }

            recordingPart++;
          } else {
            // 💡 中斷狀態中：每 3 秒敲門一次
            if (timer.tick % 3 == 0) {
              _isRecovering = true;
              try {
                GlobalManager.addLog("🔄 嘗試搶回麥克風權限...");

                final session = await as_lib.AudioSession.instance;
                await session.setActive(true);

                final dir = await getApplicationDocumentsDirectory();
                final fileName =
                    "rec_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}_p$recordingPart.m4a";
                final resumePath = '${dir.path}/$fileName';

                await audioRecorder.start(
                  const RecordConfig(
                    encoder: AudioEncoder.aacLc,
                    bitRate: 32000,
                    sampleRate: 16000,
                    numChannels: 1,
                    autoGain: false,
                    echoCancel: false,
                    noiseSuppress: false,
                  ),
                  path: resumePath,
                );

                // 💡 等待 1 秒驗證是否真的活著且有聲音，不再被騙
                await Future.delayed(const Duration(seconds: 1));
                bool alive = await audioRecorder.isRecording();
                if (alive) {
                  final amp = await audioRecorder.getAmplitude();
                  if (amp.current <= -150.0) {
                    alive = false; // 依然是空跑，視為失敗
                  }
                }

                if (alive) {
                  _isSystemInterrupted = false;
                  _deadMicCounter = 0;
                  stopwatch.reset();
                  stopwatch.start();
                  GlobalManager.addLog("✅ 成功恢復錄音 (Part $recordingPart)");

                  FlutterForegroundTask.updateService(
                    notificationTitle: '會議錄音中',
                    notificationText: '已自動接續錄製 (Part $recordingPart)',
                  );
                } else {
                  await audioRecorder.stop(); // 搶奪失敗，等下一個 3 秒
                }
              } catch (e) {
                GlobalManager.addLog("❌ 恢復重試被拒絕");
              } finally {
                _isRecovering = false;
              }
            }
          }
          return;
        }

        // --- 正常狀態 ---
        setState(() {
          timerText =
              "${stopwatch.elapsed.inMinutes.toString().padLeft(2, '0')}:${(stopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}";
        });

        if (stopwatch.elapsed.inMinutes >= 60 && !_isSystemInterrupted) {
          await handleAutoSplit();
        }
      });
      // 👆👆👆 替換結束 👆👆👆

      GlobalManager.isRecordingNotifier.value = true;
      await WakelockPlus.enable(); // 💡 新增：啟動喚醒鎖，防止手機休眠砍掉麥克風
      GlobalManager.addLog(
          "開始錄音並啟用 Wakelock 防休眠 (32kbps 瘦身模式，確保符合 Groq 大小限制)...");
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("需要麥克風權限才能錄音")));
      }
    }
  }

  Future<void> handleAutoSplit() async {
    timer?.cancel();
    final path = await audioRecorder.stop();
    stopwatch.stop();

    if (path != null) {
      String title = "會議錄音 Part $recordingPart";
      if (recordingSessionStartTime != null) {
        title += " (${DateFormat('HH:mm').format(recordingSessionStartTime!)})";
      }
      createNewNoteAndAnalyze(path, title, date: DateTime.now());
    }

    recordingPart++;
    await startRecording();
  }

  // 👇 修改：完善停止邏輯 👇
  Future<void> stopAndAnalyze({bool manualStop = false}) async {
    timer?.cancel();

    String? path;
    try {
      path = await audioRecorder.stop();
    } catch (_) {} // 忽略可能因為已經停止而產生的錯誤

    stopwatch.stop();
    GlobalManager.isRecordingNotifier.value = false;
    await WakelockPlus.disable();

    if (manualStop) {
      await FlutterForegroundTask.stopService();
    }

    // 💡 判斷：如果有檔案、且不在中斷死機狀態、且長度超過 2 秒，才儲存分析
    if (path != null &&
        !_isSystemInterrupted &&
        stopwatch.elapsed.inSeconds >= 2) {
      String title = manualStop && recordingPart == 1
          ? "會議錄音"
          : "會議錄音 Part $recordingPart";
      createNewNoteAndAnalyze(path, title, date: DateTime.now());
    } else if (path != null && _isSystemInterrupted) {
      // 若在異常期間按下停止，直接清理剛才沒錄成的碎檔
      File(path).delete().catchError((_) {});
    }

    setState(() {
      timerText = "00:00";
      _isSystemInterrupted = false; // 恢復預設
      _isRecovering = false;
      _deadMicCounter = 0; // 💡 確保停止後歸零
    });
  }

  void createNewNoteAndAnalyze(
    String path,
    String defaultTitle, {
    required DateTime date,
  }) async {
    final newNote = MeetingNote(
      id: const Uuid().v4(),
      title: "$defaultTitle (${DateFormat('yyyy/MM/dd').format(date)})",
      date: date,
      summary: ["AI 分析中..."],
      tasks: [],
      transcript: [],
      sections: [],
      audioPath: path,
      status: NoteStatus.processing,
    );
    await GlobalManager.saveNote(newNote);
    GlobalManager.analyzeNote(newNote);
    if (mounted) setState(() {});
  }

  Future<void> pickFile() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.storage,
      Permission.audio,
      Permission.mediaLibrary,
    ].request();

    if (statuses.values.any((s) => s.isGranted || s.isLimited) ||
        await Permission.storage.isGranted) {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
      );
      if (result != null) {
        File file = File(result.files.single.path!);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("正在準備上傳檔案..."),
              backgroundColor: Colors.blue,
            ),
          );
        }

        DateTime fileDate = DateTime.now();
        try {
          String fileName = result.files.single.name;
          RegExp regExp = RegExp(
              r'(20\d{2})[-_]?(\d{2})[-_]?(\d{2})[-_]?(\d{2})[-_]?(\d{2})');
          var match = regExp.firstMatch(fileName);

          if (match != null) {
            int y = int.parse(match.group(1)!);
            int m = int.parse(match.group(2)!);
            int d = int.parse(match.group(3)!);
            int h = int.parse(match.group(4)!);
            int min = int.parse(match.group(5)!);
            fileDate = DateTime(y, m, d, h, min);
            GlobalManager.addLog("從檔名成功解析真實錄音時間: $fileDate");
          } else {
            fileDate = await file.lastModified();
          }
        } catch (e) {
          GlobalManager.addLog("取得檔案時間失敗: $e");
        }

        createNewNoteAndAnalyze(file.path, "匯入錄音", date: fileDate);
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("需要存取檔案權限"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> importYoutube() async {
    final TextEditingController urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("輸入 YouTube 連結"),
        content: TextField(
          controller: urlController,
          decoration: const InputDecoration(hintText: "https://youtu.be/..."),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, urlController.text),
            child: const Text("確定"),
          ),
        ],
      ),
    );

    if (url != null && url.isNotEmpty) {
      final noteId = const Uuid().v4();
      MeetingNote note = MeetingNote(
        id: noteId,
        title: "下載中...",
        date: DateTime.now(),
        summary: ["正在解析 YouTube 來源..."],
        tasks: [],
        transcript: [],
        sections: [],
        audioPath: "",
        status: NoteStatus.downloading,
        currentStep: "正在解析影片來源...",
      );
      await GlobalManager.saveNote(note);
      if (mounted) setState(() {});

      var yt = YoutubeExplode();
      try {
        var video = await yt.videos.get(url);
        note.title = "YT: ${video.title}";
        note.currentStep = "正在下載音訊串流...";
        await GlobalManager.saveNote(note);

        var manifest = await yt.videos.streamsClient.getManifest(video.id);
        var audioStreams = manifest.audioOnly.sortByBitrate().toList();

        File? audioFile;
        for (var streamInfo in audioStreams) {
          try {
            var stream = yt.videos.streamsClient.get(streamInfo);
            final dir = await getApplicationDocumentsDirectory();
            audioFile = File('${dir.path}/${video.id}.mp4');
            var fileStream = audioFile.openWrite();

            await stream.pipe(fileStream).timeout(const Duration(seconds: 15));
            await fileStream.flush();
            await fileStream.close();
            break;
          } catch (e) {
            GlobalManager.addLog("YT純音訊串流失敗 (嘗試備案): $e");
            audioFile = null;
          }
        }

        if (audioFile == null) {
          GlobalManager.addLog("所有純音訊失敗，嘗試備用綜合串流...");
          var muxedStreams = manifest.muxed.sortByBitrate().toList();
          for (var streamInfo in muxedStreams) {
            try {
              var stream = yt.videos.streamsClient.get(streamInfo);
              final dir = await getApplicationDocumentsDirectory();
              audioFile = File('${dir.path}/${video.id}.mp4');
              var fileStream = audioFile.openWrite();

              await stream
                  .pipe(fileStream)
                  .timeout(const Duration(seconds: 20));
              await fileStream.flush();
              await fileStream.close();
              break;
            } catch (e) {
              GlobalManager.addLog("YT備用串流失敗: $e");
              audioFile = null;
            }
          }
        }

        if (audioFile == null || !(await audioFile.exists())) {
          throw Exception("下載失敗。可能受到 YouTube 機器人防護阻擋或 DNS 污染。");
        }

        note.audioPath = audioFile.path;
        note.currentStep = '準備進行分析...';
        await GlobalManager.saveNote(note);

        GlobalManager.analyzeNote(note);
      } catch (e) {
        String errorMsg = e.toString();
        if (errorMsg.contains("TimeoutException") ||
            errorMsg.contains("SocketException") ||
            errorMsg.contains("host lookup")) {
          errorMsg =
              "YouTube 伺服器已阻擋此連線 (防爬蟲機制)。\n💡 建議：請透過瀏覽器使用外部工具下載為音檔後，改用匯入上傳。";
        }

        GlobalManager.addLog("YT處理最終失敗: $errorMsg");
        note.status = NoteStatus.failed;
        note.summary = ["下載失敗:\n$errorMsg"];
        note.currentStep = '';
        await GlobalManager.saveNote(note);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text("YouTube 載入失敗，請查看紀錄了解詳情"),
              backgroundColor: Colors.red));
        }
      } finally {
        yt.close();
      }
    }
  }

  void showAddMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.mic, color: Colors.green),
              title: const Text('開始錄音'),
              onTap: () {
                Navigator.pop(context);
                toggleRecording();
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_upload, color: Colors.blue),
              title: const Text('匯入本地錄音/音檔'),
              onTap: () {
                Navigator.pop(context);
                pickFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.ondemand_video, color: Colors.red),
              title: const Text('匯入 YouTube 影片'),
              onTap: () {
                Navigator.pop(context);
                importYoutube();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(index: currentIndex, children: pages),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: GlobalManager.isRecordingNotifier,
            builder: (context, isRecording, child) {
              if (!isRecording) return const SizedBox.shrink();
              return Container(
                color: Colors.redAccent,
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 16,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Icon(Icons.mic, color: Colors.white),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "錄音中... $timerText",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          "Part $recordingPart",
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.stop_circle, color: Colors.white),
                      onPressed: toggleRecording,
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 6.0,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                icon: Icon(
                  Icons.home,
                  color: currentIndex == 0 ? Colors.blue : Colors.grey,
                ),
                onPressed: () => setState(() => currentIndex = 0),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: GlobalManager.isRecordingNotifier,
                builder: (context, isRecording, child) {
                  return FloatingActionButton(
                    onPressed: isRecording ? toggleRecording : showAddMenu,
                    backgroundColor:
                        isRecording ? Colors.red : Colors.blueAccent,
                    child: Icon(
                      isRecording ? Icons.stop : Icons.add,
                      color: Colors.white,
                    ),
                  );
                },
              ),
              IconButton(
                icon: Icon(
                  Icons.settings,
                  color: currentIndex == 1 ? Colors.blue : Colors.grey,
                ),
                onPressed: () => setState(() => currentIndex = 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    GlobalManager.loadNotes();
  }

  Future<void> togglePin(MeetingNote note) async {
    note.isPinned = !note.isPinned;
    await GlobalManager.saveNote(note);
  }

  Future<void> deleteNote(String id) async {
    await GlobalManager.deleteNote(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("會議記錄列表"), centerTitle: true),
      body: ValueListenableBuilder<List<MeetingNote>>(
          valueListenable: GlobalManager.notesNotifier,
          builder: (context, notes, child) {
            return RefreshIndicator(
              onRefresh: GlobalManager.loadNotes,
              child: notes.isEmpty
                  ? const Center(child: Text("尚無紀錄，點擊下方 + 開始"))
                  : ListView.builder(
                      itemCount: notes.length,
                      itemBuilder: (context, index) {
                        final note = notes[index];
                        return Dismissible(
                          key: Key(note.id),
                          background: Container(
                            color: Colors.red,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            child:
                                const Icon(Icons.delete, color: Colors.white),
                          ),
                          direction: DismissDirection.endToStart,
                          confirmDismiss: (direction) async {
                            return await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text("確定要刪除嗎？"),
                                content:
                                    const Text("此操作將永久刪除該筆會議紀錄與實體錄音檔，無法復原。"),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, false),
                                      child: const Text("取消")),
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, true),
                                      child: const Text("刪除",
                                          style: TextStyle(color: Colors.red))),
                                ],
                              ),
                            );
                          },
                          onDismissed: (direction) => deleteNote(note.id),
                          child: Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    note.status == NoteStatus.success
                                        ? Colors.green
                                        : (note.status == NoteStatus.failed
                                            ? Colors.red
                                            : Colors.orange),
                                child: Icon(
                                  note.status == NoteStatus.success
                                      ? Icons.check
                                      : (note.status == NoteStatus.failed
                                          ? Icons.error
                                          : Icons.hourglass_empty),
                                  color: Colors.white,
                                ),
                              ),
                              title: Text(
                                note.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    DateFormat('yyyy/MM/dd HH:mm')
                                        .format(note.date),
                                  ),
                                  if ((note.status == NoteStatus.processing ||
                                          note.status ==
                                              NoteStatus.downloading) &&
                                      note.currentStep.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4.0),
                                      child: Text(note.currentStep,
                                          style: const TextStyle(
                                              color: Colors.blue,
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  if (note.status == NoteStatus.failed)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 4.0),
                                      child: Text("處理失敗，請查看日誌",
                                          style: TextStyle(
                                              color: Colors.red,
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                ],
                              ),
                              trailing: IconButton(
                                icon: Icon(
                                  note.isPinned
                                      ? Icons.push_pin
                                      : Icons.push_pin_outlined,
                                  color:
                                      note.isPinned ? Colors.blue : Colors.grey,
                                ),
                                onPressed: () => togglePin(note),
                              ),
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        NoteDetailPage(note: note),
                                  ),
                                );
                                GlobalManager.loadNotes();
                              },
                            ),
                          ),
                        );
                      },
                    ),
            );
          }),
    );
  }
}

class NoteDetailPage extends StatefulWidget {
  final MeetingNote note;
  const NoteDetailPage({super.key, required this.note});
  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

class _NoteDetailPageState extends State<NoteDetailPage>
    with SingleTickerProviderStateMixin {
  late MeetingNote _note;
  late TabController _tabController;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  final ScrollController _transcriptScrollController = ScrollController();
  final Map<int, GlobalKey> _transcriptKeys = {};
  int _currentActiveTranscriptIndex = -1;
  final Set<String> _collapsedSections = {};

  bool _showOriginal = true;
  bool _showPhonetic = false;
  bool _showTranslation = true;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _tabController = TabController(length: 3, vsync: this);

    if (_note.status == NoteStatus.processing ||
        _note.status == NoteStatus.downloading) {
      Timer.periodic(const Duration(seconds: 3), (timer) async {
        if (!mounted) {
          timer.cancel();
          return;
        }
        await _reloadNote();
        if (_note.status == NoteStatus.success ||
            _note.status == NoteStatus.failed) {
          timer.cancel();
        }
      });
    }

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
    });
    _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) {
        setState(() => _position = p);

        if (_tabController.index == 1 && _note.transcript.isNotEmpty) {
          double currentSeconds = p.inMilliseconds / 1000.0;
          int newIndex = _note.transcript
              .lastIndexWhere((t) => currentSeconds >= t.startTime);

          if (newIndex != -1 && newIndex != _currentActiveTranscriptIndex) {
            setState(() {
              _currentActiveTranscriptIndex = newIndex;

              try {
                Section activeSec = _note.sections.lastWhere(
                    (s) => _note.transcript[newIndex].startTime >= s.startTime);
                if (_collapsedSections.contains(activeSec.title)) {
                  _collapsedSections.remove(activeSec.title);
                }
              } catch (e) {}
            });

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_transcriptKeys.containsKey(newIndex) &&
                  _transcriptKeys[newIndex]!.currentContext != null) {
                Scrollable.ensureVisible(
                  _transcriptKeys[newIndex]!.currentContext!,
                  duration: const Duration(milliseconds: 300),
                  alignment: 0.3,
                ).catchError((_) {});
              }
            });
          }
        }
      }
    });
  }

  Future<void> _reloadNote() async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      final List<dynamic> jsonList = jsonDecode(existingJson);
      final updatedNoteJson =
          jsonList.firstWhere((e) => e['id'] == _note.id, orElse: () => null);
      if (updatedNoteJson != null) {
        setState(() {
          _note = MeetingNote.fromJson(updatedNoteJson);
        });
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _transcriptScrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _playPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      File actualFile = await GlobalManager.getActualFile(_note.audioPath);
      if (await actualFile.exists()) {
        await _audioPlayer.play(DeviceFileSource(actualFile.path));
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("找不到此音檔，可能已被系統清除")));
      }
    }
  }

  Future<void> _seekTo(double seconds) async {
    File actualFile = await GlobalManager.getActualFile(_note.audioPath);
    if (await actualFile.exists()) {
      if (_duration == Duration.zero && !_isPlaying) {
        await _audioPlayer.setSource(DeviceFileSource(actualFile.path));
      }
      await _audioPlayer.seek(Duration(seconds: seconds.toInt()));
    }
  }

  Future<void> _seekAndPlay(double seconds) async {
    File actualFile = await GlobalManager.getActualFile(_note.audioPath);
    if (await actualFile.exists()) {
      await _audioPlayer.play(DeviceFileSource(actualFile.path));
      await _audioPlayer.seek(Duration(seconds: seconds.toInt()));
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("找不到此音檔")));
      }
    }
  }

  Future<void> _saveNoteUpdate() async {
    await GlobalManager.saveNote(_note);
  }

  void _editTitle() {
    TextEditingController controller = TextEditingController(text: _note.title);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("修改標題"),
        content: TextField(controller: controller),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(
            onPressed: () {
              setState(() => _note.title = controller.text);
              _saveNoteUpdate();
              Navigator.pop(context);
            },
            child: const Text("儲存"),
          ),
        ],
      ),
    );
  }

  void _reAnalyze() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("重新分析選項"),
        content: const Text("請選擇您需要的重整層級：\n\n"
            "1. 【僅重整摘要與任務】：保留現有逐字稿，僅重新生成摘要。\n\n"
            "2. 【重新校正錯字與講者】：套用最新字典與名單，校正現有逐字稿並重整摘要 (極度省時省額度)。\n\n"
            "3. 【徹底語音重聽】：重新辨識音檔，覆蓋所有資料。"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _note.status = NoteStatus.processing;
                _note.summary = ["AI 分析中 (僅重整摘要)..."];
              });
              GlobalManager.reSummarizeFromTranscript(_note).then((_) {
                if (mounted) _reloadNote();
              });
            },
            child: const Text("僅重整摘要"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _note.status = NoteStatus.processing;
                _note.summary = ["AI 正在校正錯字與講者..."];
              });
              GlobalManager.reCalibrateTranscript(_note).then((_) {
                if (mounted) _reloadNote();
              });
            },
            child: const Text("校正錯字與講者", style: TextStyle(color: Colors.green)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _note.status = NoteStatus.processing;
                _note.summary = ["AI 徹底語音重聽分析中..."];
              });
              GlobalManager.analyzeNote(_note).then((_) {
                if (mounted) _reloadNote();
              });
            },
            child: const Text("徹底語音重聽", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _changeSpeaker(int index) {
    String currentSpeaker = _note.transcript[index].speaker;
    TextEditingController customController = TextEditingController(text: "");

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("修改說話者"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("選擇既有與會者:",
                  style: TextStyle(fontWeight: FontWeight.bold)),
              ValueListenableBuilder<List<String>>(
                valueListenable: GlobalManager.participantListNotifier,
                builder: (context, participants, child) {
                  return Wrap(
                    spacing: 8,
                    children: participants.map((name) {
                      return ActionChip(
                        label: Text(name),
                        onPressed: () =>
                            _confirmSpeakerChange(index, currentSpeaker, name),
                      );
                    }).toList(),
                  );
                },
              ),
              const Divider(height: 20),
              const Text("或輸入新名稱:",
                  style: TextStyle(fontWeight: FontWeight.bold)),
              TextField(
                  controller: customController,
                  decoration: const InputDecoration(labelText: "新名稱")),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text("取消")),
          FilledButton(
            onPressed: () {
              if (customController.text.isNotEmpty) {
                GlobalManager.addParticipant(customController.text);
                _confirmSpeakerChange(
                    index, currentSpeaker, customController.text);
              }
            },
            child: const Text("確定"),
          ),
        ],
      ),
    );
  }

  void _confirmSpeakerChange(int index, String oldName, String newName) {
    Navigator.pop(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("確認修改為 $newName"),
        content: const Text("請選擇修改範圍："),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _note.transcript[index].speaker = newName;
              });
              _saveNoteUpdate();
              Navigator.pop(context);
            },
            child: const Text("僅此句"),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                for (var item in _note.transcript) {
                  if (item.speaker == oldName) item.speaker = newName;
                }
              });
              _saveNoteUpdate();
              Navigator.pop(context);
            },
            child: const Text("全部修改"),
          ),
        ],
      ),
    );
  }

  void _editTranscriptItem(int index) {
    TextEditingController controller =
        TextEditingController(text: _note.transcript[index].original);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("編輯逐字稿"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
                controller: controller,
                maxLines: 5,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(), hintText: "修改內容...")),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                    child: Text("💡 提示：在上方框選文字後可加入字典，或點擊游標位置使用斷句功能。",
                        style: TextStyle(fontSize: 10, color: Colors.grey))),
                IconButton(
                  icon: const Icon(Icons.call_split, color: Colors.blue),
                  tooltip: "從游標處斷開為兩句",
                  onPressed: () {
                    int pos = controller.selection.baseOffset;
                    if (pos > 0 && pos < controller.text.length) {
                      String part1 = controller.text.substring(0, pos).trim();
                      String part2 = controller.text.substring(pos).trim();

                      double currentStartTime =
                          _note.transcript[index].startTime;

                      double estimatedDuration = controller.text.length * 0.3;
                      double nextStartTime =
                          currentStartTime + estimatedDuration;

                      if (index + 1 < _note.transcript.length) {
                        double actualNextTime =
                            _note.transcript[index + 1].startTime;
                        if (actualNextTime < nextStartTime) {
                          nextStartTime = actualNextTime;
                        }
                      }

                      double ratio = pos / controller.text.length;
                      double newStartTime = currentStartTime +
                          ((nextStartTime - currentStartTime) * ratio);

                      setState(() {
                        _note.transcript[index].original = part1;
                        _note.transcript.insert(
                          index + 1,
                          TranscriptItem(
                            speaker: _note.transcript[index].speaker,
                            original: part2,
                            startTime:
                                double.parse(newStartTime.toStringAsFixed(1)),
                          ),
                        );
                      });
                      _saveNoteUpdate();
                      Navigator.pop(dialogContext);
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("已斷開並自動推算精準新時間！")));
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("請先點擊文字內容，指定要斷句的游標位置")));
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.bookmark_add, color: Colors.orange),
                  tooltip: "將框選文字加入字典",
                  onPressed: () {
                    if (controller.selection.isValid &&
                        !controller.selection.isCollapsed) {
                      String selectedText =
                          controller.selection.textInside(controller.text);
                      GlobalManager.addVocab(selectedText);
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("已將「$selectedText」加入字典")));
                    }
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("取消")),
          FilledButton(
            onPressed: () {
              setState(() {
                _note.transcript[index].original = controller.text;
              });
              _saveNoteUpdate();
              Navigator.pop(dialogContext);
            },
            child: const Text("儲存修改"),
          ),
        ],
      ),
    );
  }

  Future<void> _exportFile(String ext, String content) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final safeTitle = _note.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final file = File('${dir.path}/$safeTitle.$ext');

      List<int> bytes = [];
      if (ext == 'csv' || ext == 'md') {
        bytes.addAll([0xEF, 0xBB, 0xBF]);
      }
      bytes.addAll(utf8.encode(content));
      await file.writeAsBytes(bytes);

      await Share.shareXFiles([XFile(file.path)],
          text: '會議記錄匯出: ${_note.title}');
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("匯出失敗: $e")));
    }
  }

  Future<void> _exportCsv() async {
    StringBuffer csv = StringBuffer();
    csv.writeln("會議標題,${_note.title.replaceAll('"', '""')}");
    csv.writeln("會議日期,${DateFormat('yyyy/MM/dd HH:mm').format(_note.date)}\n");

    csv.writeln("【重點摘要】");
    for (var s in _note.summary) {
      csv.writeln('"${s.replaceAll('"', '""')}"');
    }
    csv.writeln("");

    csv.writeln("【待辦事項】");
    csv.writeln("任務,負責人,期限");
    for (var t in _note.tasks) {
      csv.writeln(
          '"${t.description.replaceAll('"', '""')}","${t.assignee}","${t.dueDate}"');
    }
    csv.writeln("");

    csv.writeln("【逐字稿】");
    csv.writeln("時間,說話者,原文內容,翻譯內容");
    for (var item in _note.transcript) {
      String time = GlobalManager.formatTime(item.startTime);
      String text = item.original.replaceAll('"', '""');
      String translation = item.translation.replaceAll('"', '""');
      csv.writeln('$time,${item.speaker},"$text","$translation"');
    }
    await _exportFile('csv', csv.toString());
  }

  Future<void> _exportMarkdown() async {
    StringBuffer md = StringBuffer();
    md.writeln("# ${_note.title}");
    md.writeln("日期: ${DateFormat('yyyy/MM/dd HH:mm').format(_note.date)}\n");

    md.writeln("## 📝 重點摘要");
    for (var s in _note.summary) {
      md.writeln("- $s");
    }
    md.writeln("\n## ✅ 待辦事項");
    md.writeln("| 任務 | 負責人 | 期限 |\n|---|---|---|");
    for (var t in _note.tasks) {
      md.writeln("| ${t.description} | ${t.assignee} | ${t.dueDate} |");
    }
    md.writeln("\n## 💬 逐字稿");
    for (var item in _note.transcript) {
      String time = GlobalManager.formatTime(item.startTime);
      String transSuffix =
          item.translation.isNotEmpty && item.translation != item.original
              ? ' (${item.translation})'
              : '';
      md.writeln("**$time [${item.speaker}]**: ${item.original}$transSuffix\n");
    }
    await _exportFile('md', md.toString());
  }

  // 💡 新增：匯出未經 Gemini 處理的純 STT 原始文字，用於抓蟲
  Future<void> _exportRawSTT() async {
    try {
      StringBuffer raw = StringBuffer();
      raw.writeln("【Groq STT 原始聽寫稿 (除錯用)】");
      raw.writeln("會議標題: ${_note.title}\n");
      for (var item in _note.transcript) {
        raw.writeln("[${item.startTime}s] ${item.original}");
      }

      final dir = await getApplicationDocumentsDirectory();
      final safeTitle = _note.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final file = File('${dir.path}/${safeTitle}_raw_stt.txt');
      await file.writeAsString(raw.toString());

      await Share.shareXFiles([XFile(file.path)], text: '匯出原始 STT 聽寫稿');
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("匯出失敗: $e")));
    }
  }

  Future<void> _generatePdf() async {
    final pdf = pw.Document();
    final fontRegular = await PdfGoogleFonts.notoSansTCRegular();
    final fontBold = await PdfGoogleFonts.notoSansTCBold();
    final fontKorean = await PdfGoogleFonts.notoSansKRRegular();

    pdf.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(
          base: fontRegular,
          bold: fontBold,
          fontFallback: [fontKorean],
        ),
        build: (context) => [
          pw.Header(
              level: 0,
              child: pw.Text(_note.title,
                  style: pw.TextStyle(
                      fontSize: 24, fontWeight: pw.FontWeight.bold))),
          pw.Text("日期: ${DateFormat('yyyy/MM/dd HH:mm').format(_note.date)}"),
          pw.Divider(),
          pw.Header(level: 1, child: pw.Text("重點摘要")),
          ..._note.summary.map((s) => pw.Bullet(text: s)),
          pw.SizedBox(height: 10),
          pw.Header(level: 1, child: pw.Text("待辦事項")),
          pw.Table.fromTextArray(
            headers: ["任務", "負責人", "期限"],
            data: _note.tasks
                .map((t) => [t.description, t.assignee, t.dueDate])
                .toList(),
          ),
          pw.SizedBox(height: 10),
          pw.Header(level: 1, child: pw.Text("逐字稿")),
          ..._note.transcript.map(
            (t) => pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 4),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(
                      width: 40,
                      child: pw.Text(GlobalManager.formatTime(t.startTime),
                          style: const pw.TextStyle(color: PdfColors.grey))),
                  pw.SizedBox(
                      width: 60,
                      child: pw.Text(t.speaker,
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(
                      child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                        pw.Text(t.original),
                        if (t.translation.isNotEmpty &&
                            t.translation != t.original)
                          pw.Text(t.translation,
                              style: const pw.TextStyle(
                                  color: PdfColors.blueGrey)),
                      ])),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    await Printing.sharePdf(
        bytes: await pdf.save(), filename: 'meeting_note.pdf');
  }

  Future<void> _exportAudio() async {
    try {
      File f = await GlobalManager.getActualFile(_note.audioPath);
      if (await f.exists()) {
        await Share.shareXFiles([XFile(f.path)],
            text: '匯出會議音檔: ${_note.title}');
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("找不到實體音檔，可能已被系統清除")));
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("音檔匯出失敗: $e")));
    }
  }

  Future<void> _confirmDelete() async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("確定要刪除嗎？"),
        content: const Text("此操作無法復原。"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("取消")),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("刪除", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) {
      await GlobalManager.deleteNote(_note.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _editTitle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                  child: Text(_note.title, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 4),
              const Icon(Icons.edit, size: 16, color: Colors.white54),
            ],
          ),
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: "重新分析",
              onPressed: _reAnalyze),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'pdf') _generatePdf();
              if (value == 'csv') _exportCsv();
              if (value == 'md') _exportMarkdown();
              if (value == 'raw_stt') _exportRawSTT(); // 💡 新增綁定
              if (value == 'audio') _exportAudio();
              if (value == 'delete') _confirmDelete();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'pdf', child: Text("匯出 PDF")),
              const PopupMenuItem(value: 'csv', child: Text("匯出 Excel (CSV)")),
              const PopupMenuItem(value: 'md', child: Text("匯出 Markdown")),
              const PopupMenuItem(
                  value: 'raw_stt',
                  child: Text("匯出 STT 原始聽寫稿 (除錯用)",
                      style: TextStyle(color: Colors.deepPurple))), // 💡 UI 選項
              const PopupMenuItem(
                  value: 'audio',
                  child: Text("匯出原始音檔 (壓縮轉檔用)",
                      style: TextStyle(color: Colors.blue))),
              const PopupMenuItem(
                  value: 'delete',
                  child: Text("刪除紀錄", style: TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.grey[200],
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                      _isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                      size: 40,
                      color: Colors.blue),
                  onPressed: _playPause,
                ),
                Expanded(
                  child: Slider(
                    value: _position.inSeconds.toDouble(),
                    max: _duration.inSeconds.toDouble() > 0
                        ? _duration.inSeconds.toDouble()
                        : 1.0,
                    onChanged: (v) => _seekTo(v),
                  ),
                ),
                Text(
                    "${GlobalManager.formatTime(_position.inSeconds.toDouble())} / ${GlobalManager.formatTime(_duration.inSeconds.toDouble())}"),
              ],
            ),
          ),
          TabBar(
            controller: _tabController,
            labelColor: Colors.blue,
            unselectedLabelColor: Colors.grey,
            tabs: const [
              Tab(text: "摘要 & 任務"),
              Tab(text: "逐字稿"),
              Tab(text: "段落回顧")
            ],
          ),
          Expanded(
            child: _note.status == NoteStatus.processing ||
                    _note.status == NoteStatus.downloading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(_note.currentStep.isNotEmpty
                            ? _note.currentStep
                            : "AI 雙引擎分析中...")
                      ],
                    ),
                  )
                : _note.status == NoteStatus.failed
                    ? Center(
                        child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Text("分析失敗: ${_note.summary.firstOrNull}",
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.red))))
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildSummaryTab(),
                          _buildTranscriptTab(),
                          _buildSectionTab()
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("📝 重點摘要",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ..._note.summary.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("• ", style: TextStyle(fontSize: 16)),
                  Expanded(
                      child: Text(s, style: const TextStyle(fontSize: 16))),
                ],
              ),
            ),
          ),
          const Divider(height: 32),
          const Text("✅ 待辦事項",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ..._note.tasks.map(
            (t) => Card(
              child: ListTile(
                leading: const Icon(Icons.check_box_outline_blank),
                title: Text(t.description),
                subtitle: Text("負責人: ${t.assignee}  期限: ${t.dueDate}"),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParsedText(TranscriptItem item) {
    List<Widget> widgets = [];

    if (_showOriginal && item.original.isNotEmpty) {
      widgets.add(Text(item.original,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)));
    }
    if (_showPhonetic && item.phonetic.isNotEmpty) {
      widgets.add(Text(item.phonetic,
          style: const TextStyle(
              fontSize: 14,
              color: Colors.blueGrey,
              fontStyle: FontStyle.italic)));
    }
    if (_showTranslation &&
        item.translation.isNotEmpty &&
        item.translation != item.original) {
      widgets.add(Text(item.translation,
          style: TextStyle(fontSize: 16, color: Colors.green.shade700)));
    }

    if (widgets.isEmpty) {
      return const Text("...", style: TextStyle(color: Colors.grey));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildTranscriptTab() {
    List<Widget> listItems = [];
    if (_note.transcript.isNotEmpty) {
      listItems.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.grey.shade50,
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              const Icon(Icons.g_translate, size: 18, color: Colors.blueGrey),
              const Text("多語系：",
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.blueGrey,
                      fontWeight: FontWeight.bold)),
              FilterChip(
                label: const Text("原文", style: TextStyle(fontSize: 12)),
                selected: _showOriginal,
                onSelected: (val) => setState(() => _showOriginal = val),
                visualDensity: VisualDensity.compact,
                selectedColor: Colors.blue.shade100,
              ),
              FilterChip(
                label: const Text("拼音", style: TextStyle(fontSize: 12)),
                selected: _showPhonetic,
                onSelected: (val) => setState(() => _showPhonetic = val),
                visualDensity: VisualDensity.compact,
                selectedColor: Colors.blue.shade100,
              ),
              FilterChip(
                label: const Text("翻譯", style: TextStyle(fontSize: 12)),
                selected: _showTranslation,
                onSelected: (val) => setState(() => _showTranslation = val),
                visualDensity: VisualDensity.compact,
                selectedColor: Colors.blue.shade100,
              ),
            ],
          ),
        ),
      );
    }

    String? currentChapter;

    String getSpeakerAvatarChar(String name) {
      if (name.isEmpty) return "?";
      String cleanName = name.trim();

      if (cleanName.toLowerCase().startsWith('speaker ')) {
        return cleanName.split(' ').last[0].toUpperCase();
      }
      if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(cleanName) &&
          cleanName.length >= 2) {
        return cleanName.substring(cleanName.length - 1);
      }
      if (cleanName.contains(' ')) {
        return cleanName.split(' ').last[0].toUpperCase();
      }
      return cleanName[0].toUpperCase();
    }

    for (int i = 0; i < _note.transcript.length; i++) {
      final item = _note.transcript[i];

      Section? sec;
      try {
        sec = _note.sections.lastWhere((s) => item.startTime >= s.startTime);
      } catch (e) {
        sec = null;
      }

      if (sec != null && sec.title != currentChapter) {
        currentChapter = sec.title;
        bool isCollapsed = _collapsedSections.contains(currentChapter);

        listItems.add(
          InkWell(
            onTap: () {
              setState(() {
                if (_collapsedSections.contains(sec!.title)) {
                  _collapsedSections.remove(sec.title);
                } else {
                  _collapsedSections.add(sec.title);
                }
              });
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              color: Colors.blue.shade100,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("🔖 $currentChapter",
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade900)),
                  Icon(isCollapsed ? Icons.expand_more : Icons.expand_less,
                      color: Colors.blue.shade900),
                ],
              ),
            ),
          ),
        );
      }

      if (sec != null && _collapsedSections.contains(sec.title)) {
        continue;
      }

      if (!_transcriptKeys.containsKey(i)) _transcriptKeys[i] = GlobalKey();
      bool isActive = i == _currentActiveTranscriptIndex;

      listItems.add(
        Material(
          key: _transcriptKeys[i],
          color: isActive ? Colors.yellow.withOpacity(0.3) : Colors.transparent,
          child: InkWell(
            onTap: () => _seekTo(item.startTime),
            onDoubleTap: () => _seekAndPlay(item.startTime),
            onLongPress: () => _editTranscriptItem(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => _changeSpeaker(i),
                    child: CircleAvatar(
                        child: Text(getSpeakerAvatarChar(item.speaker))),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.speaker,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: Colors.blueGrey)),
                        const SizedBox(height: 4),
                        _buildParsedText(item),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    GlobalManager.formatTime(item.startTime),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      controller: _transcriptScrollController,
      child: Column(
        children: listItems,
      ),
    );
  }

  Widget _buildSectionTab() {
    return ListView.builder(
      itemCount: _note.sections.length,
      itemBuilder: (context, index) {
        final section = _note.sections[index];
        return Card(
          margin: const EdgeInsets.all(8),
          child: ListTile(
            title: Text(section.title,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
                "${GlobalManager.formatTime(section.startTime)} - ${GlobalManager.formatTime(section.endTime)}"),
            leading: const Icon(Icons.bookmark),
            onTap: () {
              setState(() {
                _collapsedSections.remove(section.title);
              });

              _tabController.animateTo(1);

              int targetIndex = _note.transcript
                  .indexWhere((t) => t.startTime >= section.startTime);
              if (targetIndex != -1) {
                setState(() => _currentActiveTranscriptIndex = targetIndex);

                void tryScroll(int retries) {
                  if (!mounted) return;
                  final ctx = _transcriptKeys[targetIndex]?.currentContext;

                  if (ctx != null) {
                    Scrollable.ensureVisible(
                      ctx,
                      duration: const Duration(milliseconds: 300),
                      alignment: 0.1,
                    ).catchError((_) {});
                  } else if (retries > 0) {
                    Future.delayed(const Duration(milliseconds: 100),
                        () => tryScroll(retries - 1));
                  }
                }

                Future.delayed(
                    const Duration(milliseconds: 100), () => tryScroll(10));
              }

              _seekAndPlay(section.startTime);
            },
          ),
        );
      },
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _groqKeyController = TextEditingController();
  final TextEditingController _vocabController = TextEditingController();
  final TextEditingController _participantController = TextEditingController();

  String _analysisStrategy = 'groq_gemini'; // 預設推薦雙引擎
  String _sttLanguage = 'zh'; // 💡 新增狀態變數
  bool _isLoadingModels = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text = prefs.getString('api_key') ?? '';
      _groqKeyController.text = prefs.getString('groq_api_key') ?? '';
      _analysisStrategy = prefs.getString('analysis_strategy') ?? 'groq_gemini';
      _sttLanguage = prefs.getString('stt_language') ?? 'zh'; // 💡 讀取
    });
  }

  Future<void> _testApiConnection() async {
    final rawKeys = _apiKeyController.text.trim();
    if (rawKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("請先輸入 Gemini API Key"),
            backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() => _isLoadingModels = true);

    final firstKey = rawKeys
        .split(',')
        .map((e) => e.trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => '');

    try {
      await GeminiRestApi.getAvailableModels(firstKey);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("✅ Gemini API 測試成功！網路連線正常"),
            backgroundColor: Colors.green),
      );
      _saveSettings();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("❌ Gemini 測試失敗: $e"), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isLoadingModels = false);
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text);
    await prefs.setString('groq_api_key', _groqKeyController.text);
    await prefs.setString('analysis_strategy', _analysisStrategy);
    await prefs.setString('stt_language', _sttLanguage); // 💡 寫入

    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("設定已儲存")));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 💡 動態成本計算邏輯
    int daysSinceFirstUse = UsageTracker.firstUseDate == null
        ? 1
        : DateTime.now().difference(UsageTracker.firstUseDate!).inDays;
    if (daysSinceFirstUse < 1) daysSinceFirstUse = 1;

    double groqCost =
        (UsageTracker.groqAudioSeconds / 3600) * 0.10; // 每小時 0.10 USD
    double geminiTextCost =
        UsageTracker.geminiTextRequests * 0.0001125; // 粗估每次請求 1500 tokens
    double geminiAudioCost =
        (UsageTracker.geminiAudioSeconds / 60) * 0.0012; // 粗估 Flash 音訊價格

    double totalCurrentCost = groqCost + geminiTextCost + geminiAudioCost;
    double projectedMonthlyCost = (totalCurrentCost / daysSinceFirstUse) * 30;

    return Scaffold(
      appBar: AppBar(
        title: const Text("設定"),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report, color: Colors.red),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LogViewerPage()),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            "API 設定 (安全遮蔽)",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _apiKeyController,
            maxLines: 1,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: "Gemini API Keys",
              hintText: "多組 Key 請用半形逗號 (,) 分隔，將自動接力",
              border: OutlineInputBorder(),
              suffixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _groqKeyController,
            maxLines: 1,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: "Groq API Key (用於雙引擎 STT)",
              hintText: "至 console.groq.com 免費申請",
              border: OutlineInputBorder(),
              suffixIcon: Icon(Icons.mic_external_on),
            ),
          ),
          const SizedBox(height: 10),
          ElevatedButton.icon(
            onPressed: _isLoadingModels ? null : _testApiConnection,
            icon: _isLoadingModels
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: Text(_isLoadingModels ? "連線測試中..." : "儲存並測試連線"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade50,
              foregroundColor: Colors.green.shade800,
            ),
          ),
          const SizedBox(height: 20),

          const Text(
            "分析模式 (AI 核心策略)",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(8)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _analysisStrategy,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                      value: 'groq_gemini',
                      child: Text("🥇 雙引擎模式 (Groq 聽寫 + Gemini 摘要)")),
                  DropdownMenuItem(
                      value: 'flash', child: Text("原生備案模式 (純 Gemini Flash)")),
                  DropdownMenuItem(
                      value: 'pro', child: Text("精準高密模式 (純 Gemini Pro)")),
                ],
                onChanged: (val) {
                  setState(() => _analysisStrategy = val!);
                  _saveSettings();
                },
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _analysisStrategy == 'groq_gemini'
                ? "💡 極度推薦：時間軸 100% 準確，解析速度快 10 倍，且極度省 Token。"
                : (_analysisStrategy == 'flash'
                    ? "超過 25MB 大檔備案 (速度快)"
                    : "⚠️ 警告：超過 25MB 大檔備案 (極耗額度)"),
            style: TextStyle(
                fontSize: 12,
                color: _analysisStrategy == 'pro' ? Colors.red : Colors.green),
          ),

          const SizedBox(height: 20),
          // 💡 新增：STT 語系選擇下拉選單
          const Text(
            "語音辨識主要語言 (STT Language)",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(8)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _sttLanguage,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                      value: 'zh', child: Text("🇹🇼 繁體中文 (預設，適合中英夾雜)")),
                  DropdownMenuItem(
                      value: 'en', child: Text("🇺🇸 英文為主 (English)")),
                  DropdownMenuItem(value: 'ja', child: Text("🇯🇵 日文為主 (日本語)")),
                  DropdownMenuItem(value: 'ko', child: Text("🇰🇷 韓文為主 (한국어)")),
                  DropdownMenuItem(
                      value: 'auto', child: Text("🌐 自動偵測 (無明顯主導語言時使用)")),
                ],
                onChanged: (val) {
                  setState(() => _sttLanguage = val!);
                  _saveSettings();
                },
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            "💡 提示：若會議有明確主導語言請明確選擇，可極大化消滅 STT 幻覺。",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),

          const SizedBox(height: 20),
          Card(
            color: Colors.blue.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.monetization_on, color: Colors.blue),
                          SizedBox(width: 8),
                          Text("動態成本估算器",
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16)),
                        ],
                      ),
                      Text("第 $daysSinceFirstUse 天",
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                      "🎙️ Groq STT 音訊: ${(UsageTracker.groqAudioSeconds / 3600).toStringAsFixed(2)} 小時",
                      style: const TextStyle(fontSize: 13)),
                  Text("📝 Gemini 純文字請求: ${UsageTracker.geminiTextRequests} 次",
                      style: const TextStyle(fontSize: 13)),
                  Text(
                      "🔊 Gemini 備案音訊: ${(UsageTracker.geminiAudioSeconds / 3600).toStringAsFixed(2)} 小時",
                      style: const TextStyle(fontSize: 13)),
                  const Divider(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("目前累積成本 (約):"),
                      Text("\$${totalCurrentCost.toStringAsFixed(3)} USD",
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("預估 30 天月費:"),
                      Text("\$${projectedMonthlyCost.toStringAsFixed(2)} USD",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, color: Colors.red)),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),
          const Text(
            "預設與會者 (常用名單)",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _participantController,
                  decoration: const InputDecoration(hintText: "輸入姓名 (如: 小明)"),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () {
                  if (_participantController.text.isNotEmpty) {
                    GlobalManager.addParticipant(_participantController.text);
                    _participantController.clear();
                    setState(() {});
                  }
                },
              ),
            ],
          ),
          ValueListenableBuilder<List<String>>(
            valueListenable: GlobalManager.participantListNotifier,
            builder: (ctx, list, _) => Wrap(
              spacing: 8,
              children: list
                  .map(
                    (name) => Chip(
                      label: Text(name),
                      onDeleted: () => GlobalManager.removeParticipant(name),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            "專有詞彙庫 (幫助 AI 辨識)",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _vocabController,
                  decoration: const InputDecoration(hintText: "輸入詞彙"),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () {
                  if (_vocabController.text.isNotEmpty) {
                    GlobalManager.addVocab(_vocabController.text);
                    _vocabController.clear();
                    setState(() {});
                  }
                },
              ),
            ],
          ),
          ValueListenableBuilder<List<String>>(
            valueListenable: GlobalManager.vocabListNotifier,
            builder: (ctx, list, _) => Wrap(
              spacing: 8,
              children: list
                  .map(
                    (word) => Chip(
                      label: Text(word),
                      onDeleted: () => GlobalManager.removeVocab(word),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class LogViewerPage extends StatelessWidget {
  const LogViewerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("系統日誌 (Debug)"),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              GlobalManager.logsNotifier.value = [];
            },
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () async {
              try {
                final text = GlobalManager.logsNotifier.value.join('\n');
                if (text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("沒有日誌可分享")),
                  );
                  return;
                }
                final dir = await getTemporaryDirectory();
                final file = File('${dir.path}/app_debug_log.txt');
                await file.writeAsString(text);
                await Share.shareXFiles([XFile(file.path)],
                    text: 'Meeting Recorder Debug Log');
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("匯出失敗: $e")),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final text = GlobalManager.logsNotifier.value.join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("日誌已複製到剪貼簿")),
              );
            },
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: ValueListenableBuilder<List<String>>(
        valueListenable: GlobalManager.logsNotifier,
        builder: (context, logs, child) {
          if (logs.isEmpty) {
            return const Center(
                child: Text("尚無日誌", style: TextStyle(color: Colors.white)));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: logs.length,
            separatorBuilder: (_, __) =>
                const Divider(color: Colors.white24, height: 1),
            itemBuilder: (context, index) {
              final log = logs[index];
              Color textColor = Colors.greenAccent;
              if (log.contains("❌") ||
                  log.contains("失敗") ||
                  log.contains("Error") ||
                  log.contains("Exception") ||
                  log.contains("⚠️")) {
                textColor = Colors.redAccent;
              } else if (log.contains("Step") || log.contains("準備")) {
                textColor = Colors.yellowAccent;
              }

              return SelectableText(
                log,
                style: TextStyle(
                    color: textColor, fontFamily: 'monospace', fontSize: 12),
              );
            },
          );
        },
      ),
    );
  }
}

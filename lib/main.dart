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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await GlobalManager.init();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: MainAppShell()),
  );
}

enum NoteStatus { downloading, processing, success, failed }

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

// --- Groq API (Whisper V3) ---
class GroqApi {
  static Future<List<dynamic>> transcribeAudio(
      String apiKey, File audioFile) async {
    _log("啟動 Groq Whisper V3 引擎進行高精度 STT...");
    var request = http.MultipartRequest('POST',
        Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'));

    request.headers.addAll({'Authorization': 'Bearer $apiKey'});
    request.fields['model'] = 'whisper-large-v3';
    request.fields['response_format'] = 'verbose_json';

    request.files
        .add(await http.MultipartFile.fromPath('file', audioFile.path));

    var response = await request.send().timeout(const Duration(minutes: 5));
    var responseBody = await response.stream.bytesToString();

    if (response.statusCode == 200) {
      var json = jsonDecode(responseBody);
      _log("✅ Groq STT 辨識完成！成功取得精準時間軸資料。");
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
        '準備上傳 (使用 Key ${_maskKey(apiKey)}): $displayName (${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB)');

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

  // 這是給純語音 (原生Gemini) 使用的，需要綁定單一 Key
  static Future<String> generateContent(
    String lockedApiKey,
    List<String> modelsToTry,
    String prompt,
    String fileUri,
    String mimeType,
  ) async {
    for (String currentModel in modelsToTry) {
      final url = Uri.parse(
          '$_baseUrl/v1beta/models/$currentModel:generateContent?key=$lockedApiKey');

      int retryCount = 0;
      int maxRetries = 5;

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
            double waitSeconds = 20.0;
            if (response.body.contains('RESOURCE_EXHAUSTED'))
              waitSeconds = 60.0;
            _log("⚠️ 額度耗盡 (429)，啟動智慧休眠等待 ${waitSeconds.toInt()} 秒...");
            await Future.delayed(Duration(seconds: waitSeconds.toInt()));
            retryCount++;
            continue;
          }

          if (response.statusCode == 404 || response.statusCode == 400) {
            _log("⚠️ 模型 $currentModel 不可用，切換備援模型...");
            break;
          }

          if (response.statusCode != 200)
            throw Exception('Generate failed: ${response.body}');

          return jsonDecode(response.body)['candidates'][0]['content']['parts']
              [0]['text'];
        } catch (e) {
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
    throw Exception('已嘗試所有策略模型皆失敗，可能額度已徹底耗盡，請稍後再試。');
  }

  // 💡 核心更新：無縫接力的純文字 API 請求 (接受完整 API Keys 陣列)
  static Future<String> generateTextOnly(
      List<String> apiKeys, List<String> modelsToTry, String prompt,
      {Function(String)? onWait}) async {
    for (String currentModel in modelsToTry) {
      for (int k = 0; k < apiKeys.length; k++) {
        String currentKey = apiKeys[k];
        final url = Uri.parse(
            '$_baseUrl/v1beta/models/$currentModel:generateContent?key=$currentKey');

        int retryCount = 0;
        int maxRetries = 3; // 每個 Key 容忍 3 次網路波動

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
                break; // 💡 打破 while 迴圈，讓外層 for 迴圈直接進入下一把 Key (k++)
              } else {
                // 若只是單純送太快 (Rate limit)
                if (onWait != null) onWait("請求過快，短暫休眠 15 秒...");
                await Future.delayed(const Duration(seconds: 15));
                retryCount++;
                continue;
              }
            }

            if (response.statusCode == 404 || response.statusCode == 400)
              break; // 模型不存在，跳出換下一個模型

            if (response.statusCode != 200) {
              throw Exception('Generate failed: ${response.body}');
            }

            return jsonDecode(response.body)['candidates'][0]['content']
                ['parts'][0]['text'];
          } catch (e) {
            if (retryCount < maxRetries - 1 &&
                !e.toString().contains('Generate failed')) {
              await Future.delayed(const Duration(seconds: 5));
              retryCount++;
              continue;
            } else {
              break; // 換下一把 Key
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
    final List<String> vocabList = vocabListNotifier.value;
    final List<String> participantList = participantListNotifier.value;

    try {
      if (apiKeys.isEmpty) throw Exception("請先設定 Gemini API Key");

      // 💡 限定嚴格模型組合
      List<String> modelsToTry = strategy == 'pro'
          ? ['gemini-pro-latest', 'gemini-2.5-pro']
          : ['gemini-flash-latest', 'gemini-2.5-flash'];

      final audioFile = await getActualFile(note.audioPath);
      if (!await audioFile.exists()) throw Exception("找不到音訊檔案");

      // 智能體積判定 (25MB 限制)
      final int fileSize = await audioFile.length();
      final double fileSizeMB = fileSize / (1024 * 1024);
      final bool isOversized = fileSizeMB >= 25.0;

      if (strategy == 'groq_gemini' && isOversized) {
        _log("⚠️ 檔案大小 (${fileSizeMB.toStringAsFixed(1)}MB) 超過 Groq 25MB 限制！");
        _log("⚡ 系統自動觸發分流，將使用 Gemini 原生引擎分析大型檔案...");
        strategy = 'flash'; // 強制切換回 Flash 策略
        modelsToTry = ['gemini-flash-latest', 'gemini-2.5-flash'];
      }

      final tempPlayer = AudioPlayer();
      await tempPlayer.setSource(DeviceFileSource(audioFile.path));
      final duration = await tempPlayer.getDuration();
      await tempPlayer.dispose();
      double totalSeconds = (duration?.inMilliseconds ?? 0) / 1000.0;

      if (strategy == 'groq_gemini') {
        if (groqKey.isEmpty) throw Exception("選擇了高精度雙引擎，但未設定 Groq API Key");

        note.currentStep = "Groq STT 引擎分析中...";
        await saveNote(note);

        List<dynamic> whisperSegments =
            await GroqApi.transcribeAudio(groqKey, audioFile);

        if (whisperSegments.isEmpty) {
          throw Exception("音檔無內容或辨識失敗");
        }

        List<TranscriptItem> fullTranscript = [];
        StringBuffer currentChunk = StringBuffer();

        int totalSegments = whisperSegments.length;
        int batchSize = 40; // 每 40 句話送一次
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

            String textPrompt = """
            以下是外部 STT 引擎產生的純文字逐字稿（帶有精準時間戳）：
            ---
            $currentChunk
            ---
            請扮演會議記錄員，執行以下任務：
            1. 根據對話上下文，判斷說話者是誰 (Speaker A, Speaker B 等)。
            2. 若整句話是外文，請翻譯成繁體中文。
            3. 絕對嚴格保留原始括號內的 [秒數]，填入 startTime。
            
            回傳格式：包含 speaker, original, phonetic, translation, startTime 的純 JSON 陣列。
            """;

            try {
              // 💡 無縫接力：傳入完整的 apiKeys 陣列，讓系統自動輪替
              final chunkResponse = await GeminiRestApi.generateTextOnly(
                  apiKeys, modelsToTry, textPrompt, onWait: (msg) async {
                note.currentStep = "講者辨識 ($chunkCount/$totalBatches) - $msg";
                await saveNote(note);
              });

              final List<dynamic> parsedList = _parseJsonList(chunkResponse);
              fullTranscript.addAll(
                  parsedList.map((e) => TranscriptItem.fromJson(e)).toList());

              currentChunk.clear();
              _log("已完成第 $chunkCount/$totalBatches 批次講者辨識。");
            } catch (e) {
              _log("⚠️ 第 $chunkCount 批次講者辨識失敗跳過: $e");
              currentChunk.clear();
              continue;
            }
          }
        }

        note.transcript = fullTranscript;

        note.currentStep = "最終摘要生成中...";
        await saveNote(note);
        await reSummarizeFromTranscript(note);
        return;
      } else {
        // --- Gemini 原生語音處理模式 (處理 >25MB) ---
        // 原生語音因為綁定 File URI，仍須鎖定第一把 Key (隨機選取分攤流量)
        apiKeys.shuffle(Random());
        final String lockedKey = apiKeys.first;

        int chunkSize = strategy == 'pro' ? 120 : 300;

        if (totalSeconds <= 0) totalSeconds = chunkSize * 36.0;
        int maxChunks = (totalSeconds / chunkSize).ceil();
        if (maxChunks == 0) maxChunks = 1;

        note.currentStep = "上傳大型音訊檔案中...";
        await saveNote(note);

        final fileInfo = await GeminiRestApi.uploadFile(
            lockedKey, audioFile, 'audio/mp4', note.title);
        final String fileUri = fileInfo['uri'];
        final String fileName = fileInfo['name'].split('/').last;
        await GeminiRestApi.waitForFileActive(lockedKey, fileName);

        note.currentStep = "AI 正在分析會議摘要...";
        await saveNote(note);

        String overviewPrompt = """
        專有詞彙庫：${vocabList.join(', ')}。預設與會者名單：${participantList.join(', ')}。
        請直接回傳純 JSON 格式，包含: title, summary, tasks, sections。
        sections 的 startTime 與 endTime 必須是「絕對秒數」（純數字）。
        """;

        final overviewResponseText = await GeminiRestApi.generateContent(
            lockedKey, modelsToTry, overviewPrompt, fileUri, 'audio/mp4');
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

        List<TranscriptItem> fullTranscript = [];
        int emptyCount = 0;

        for (int i = 0; i < maxChunks; i++) {
          note.currentStep = "原生語音聽打 (${i + 1}/$maxChunks)...";
          await saveNote(note);
          _log(note.currentStep);

          double chunkStart = (i * chunkSize).toDouble();
          double chunkEnd = ((i + 1) * chunkSize).toDouble();

          String transcriptPrompt = """
          請扮演一位極度專業的「多語系逐字稿聽打員」，針對 $chunkStart 秒 到 $chunkEnd 秒的音訊提供一字不漏的逐字稿。
          1. 【強制短句斷點】：單一句子長度超過 10 秒必須斷開。
          2. 【防範時間軸偏移】：遇到超過 5 秒的空白必須插入系統節點校準時間。
          請回傳純 JSON 陣列。
          """;

          try {
            final chunkResponseText = await GeminiRestApi.generateContent(
                lockedKey, modelsToTry, transcriptPrompt, fileUri, 'audio/mp4');
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
          } catch (e) {
            _log("分段 $i 最終分析失敗: $e");
            break;
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

  static Future<void> completeMissingTranscript(MeetingNote note) async {
    _log("雙引擎模式已啟動，補全功能自動轉向重新整理摘要");
    await reSummarizeFromTranscript(note);
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

      // 💡 嚴格模型組合
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

      String prompt = """
      以下是會議逐字稿：
      ---
      $transcriptText
      ---
      請根據上方文字，重新整理會議摘要與任務。
      1. 內容必須 100% 來自上方文字，不可腦補。
      2. sections 的 startTime 與 endTime 必須填寫「純數字的秒數」，絕不可用 MM:SS！
      
      請回傳包含 title, summary, tasks, sections 的純 JSON 格式。
      """;

      // 💡 無縫接力處理摘要
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

class _MainAppShellState extends State<MainAppShell> {
  int currentIndex = 0;
  final AudioRecorder audioRecorder = AudioRecorder();
  final Stopwatch stopwatch = Stopwatch();
  Timer? timer;
  String timerText = "00:00";
  int recordingPart = 1;
  DateTime? recordingSessionStartTime;

  final List<Widget> pages = [const HomePage(), const SettingsPage()];

  @override
  void dispose() {
    timer?.cancel();
    audioRecorder.dispose();
    super.dispose();
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
    ].request();

    if (statuses[Permission.microphone]!.isGranted) {
      final dir = await getApplicationDocumentsDirectory();
      final fileName =
          "rec_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}_p$recordingPart.m4a";
      final path = '${dir.path}/$fileName';

      // 💡 關鍵優化：32kbps 位元率，1小時錄音僅 14MB，完美符合 Groq 限制
      await audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: false,
          noiseSuppress: false,
        ),
        path: path,
      );

      stopwatch.reset();
      stopwatch.start();

      timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted) return;
        setState(() {
          timerText =
              "${stopwatch.elapsed.inMinutes.toString().padLeft(2, '0')}:${(stopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}";
        });

        // 避免檔案過大被 Groq 拒絕，單檔 60 分鐘自動分段
        if (stopwatch.elapsed.inMinutes >= 60) {
          await handleAutoSplit();
        }
      });

      GlobalManager.isRecordingNotifier.value = true;
      GlobalManager.addLog("開始錄音 (32kbps 瘦身模式，確保符合 Groq 大小限制)...");
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

  Future<void> stopAndAnalyze({bool manualStop = false}) async {
    timer?.cancel();
    final path = await audioRecorder.stop();
    stopwatch.stop();
    GlobalManager.isRecordingNotifier.value = false;

    if (path != null) {
      String title = manualStop && recordingPart == 1
          ? "會議錄音"
          : "會議錄音 Part $recordingPart";
      createNewNoteAndAnalyze(path, title, date: DateTime.now());
    }
    setState(() {
      timerText = "00:00";
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
          fileDate = await file.lastModified();

          if (DateTime.now().difference(fileDate).inMinutes < 5) {
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
            }
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
        content: const Text(
            "您想如何重新分析？\n\n1. 【基於逐字稿】：保留修改，僅重新整理摘要與任務。\n\n2. 【語音重聽】：徹底覆蓋現有資料。"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _note.status = NoteStatus.processing;
                _note.summary = ["AI 分析中 (基於逐字稿)..."];
              });
              GlobalManager.reSummarizeFromTranscript(_note).then((_) {
                if (mounted) _reloadNote();
              });
            },
            child: const Text("基於逐字稿"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _note.status = NoteStatus.processing;
                _note.summary = ["AI 語音重聽分析中..."];
              });
              GlobalManager.analyzeNote(_note).then((_) {
                if (mounted) _reloadNote();
              });
            },
            child: const Text("語音重聽", style: TextStyle(color: Colors.red)),
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
              if (value == 'delete') _confirmDelete();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'pdf', child: Text("匯出 PDF")),
              const PopupMenuItem(value: 'csv', child: Text("匯出 Excel (CSV)")),
              const PopupMenuItem(value: 'md', child: Text("匯出 Markdown")),
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
  bool _isLoadingModels = false;
  double _monthlyHours = 10.0;

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

    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("設定已儲存")));
    }
  }

  @override
  Widget build(BuildContext context) {
    double monthlyTokens = _monthlyHours * 115200;
    double proCost = (monthlyTokens / 1000000) * 2.0;
    double flashCost = (monthlyTokens / 1000000) * 0.075;

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
                      value: 'flash', child: Text("日常會議模式 (純 Gemini Flash)")),
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
          Card(
            color: Colors.blue.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.monetization_on, color: Colors.blue),
                      SizedBox(width: 8),
                      Text("Pay-as-you-go 成本估算器",
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text("預估每月會議總長度: ${_monthlyHours.toInt()} 小時"),
                  Slider(
                    value: _monthlyHours,
                    min: 1,
                    max: 100,
                    divisions: 99,
                    label: "${_monthlyHours.toInt()} 小時",
                    onChanged: (val) => setState(() => _monthlyHours = val),
                  ),
                  const Divider(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("純 Gemini Pro (極昂貴):"),
                      Text("\$${proCost.toStringAsFixed(2)} USD / 月",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, color: Colors.red)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("雙引擎 (Groq + Flash):"),
                      Text("\$${(flashCost * 0.1).toStringAsFixed(3)} USD / 月",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.green)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text("(*雙引擎因不用傳輸音檔給 Gemini，成本大幅降低 90% 以上)",
                      style: TextStyle(fontSize: 10, color: Colors.grey)),
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

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
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'dart:isolate';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audio_session/audio_session.dart' as as_lib;
import 'package:url_launcher/url_launcher.dart';

const String APP_VERSION = "1.0.62"; // 💡 設定頁新增STT引擎設定、YT下載網頁連結，增加Gemini文稿翻譯等待回應時間

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await GlobalManager.init();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: MainAppShell()),
  );
}

enum NoteStatus { downloading, processing, success, failed }

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
  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {}
}

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
        parsedTime = double.tryParse(st.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
      }
      return TranscriptItem(
        speaker: json['speaker']?.toString() ?? 'Unknown',
        original: json['original']?.toString() ?? json['text']?.toString() ?? '',
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
  TaskItem({required this.description, this.assignee = '未定', this.dueDate = '未定'});

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
  Section({required this.title, required this.startTime, required this.endTime});

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
  List<String> audioParts;
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
    this.audioParts = const [],
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
        'audioParts': audioParts,
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
      audioPath: json['audioPath'] ?? '',
      audioParts: (json['audioParts'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          (json['audioPath'] != null && json['audioPath'].toString().isNotEmpty
              ? [json['audioPath']]
              : []),
      summary: List<String>.from(json['summary'] ?? []),
      tasks: (json['tasks'] as List<dynamic>?)?.map((e) => TaskItem.fromJson(e)).toList() ?? [],
      transcript: (json['transcript'] as List<dynamic>?)?.map((e) => TranscriptItem.fromJson(e)).toList() ?? [],
      sections: (json['sections'] as List<dynamic>?)?.map((e) => Section.fromJson(e)).toList() ?? [],
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

class UsageTracker {
  static DateTime? firstUseDate;
  static double groqAudioSeconds = 0;
  static double deepgramAudioSeconds = 0;
  static int geminiTextRequests = 0;
  static double geminiAudioSeconds = 0;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    String? dateStr = prefs.getString('usage_first_date');
    if (dateStr != null) firstUseDate = DateTime.tryParse(dateStr);
    if (firstUseDate == null) {
      firstUseDate = DateTime.now();
      await prefs.setString('usage_first_date', firstUseDate!.toIso8601String());
    }
    groqAudioSeconds = prefs.getDouble('usage_groq_seconds') ?? 0;
    deepgramAudioSeconds = prefs.getDouble('usage_deepgram_seconds') ?? 0;
    geminiTextRequests = prefs.getInt('usage_gemini_texts') ?? 0;
    geminiAudioSeconds = prefs.getDouble('usage_gemini_audio_seconds') ?? 0;
  }

  static Future<void> addGroqSeconds(double seconds) async {
    groqAudioSeconds += seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('usage_groq_seconds', groqAudioSeconds);
  }

  static Future<void> addDeepgramSeconds(double seconds) async {
    deepgramAudioSeconds += seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('usage_deepgram_seconds', deepgramAudioSeconds);
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

class GroqApi {
  static Future<List<dynamic>> transcribeAudio(String apiKey, File audioFile, double audioDurationSeconds, String sttLanguage, List<String> vocabList) async {
    final prefs = await SharedPreferences.getInstance();
    double temp = prefs.getDouble('groq_temperature') ?? 0.0;
    
    String contextPrefix = vocabList.isNotEmpty ? "專有名詞：${vocabList.join(', ')}。" : "";
    String finalPrompt = "";
    switch (sttLanguage) {
      case 'zh': finalPrompt = '$contextPrefix這是一段真實的會議錄音，請精準聽寫內容。'; break;
      case 'en': finalPrompt = '$contextPrefix This is a real meeting recording, please transcribe accurately.'; break;
      case 'ja': finalPrompt = '$contextPrefixこれは実際の会議の録音です。正確に文字起こししてください。'; break;
      case 'ko': finalPrompt = '$contextPrefix실제 회의 녹음입니다. 정확하게 기록해 주세요.'; break;
      case 'auto': default: finalPrompt = '${contextPrefix}Meeting transcription. 會議紀錄。'; break;
    }

    int retries = 3;
    while (retries > 0) {
      try {
        if (retries == 3) _log("啟動 Groq 引擎 (語系: $sttLanguage, Temp: $temp)...");
        else _log("⚠️ 網路不穩，正在重新嘗試上傳至 Groq (剩餘 $retries 次)...");

        var request = http.MultipartRequest('POST', Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions'));
        request.headers.addAll({'Authorization': 'Bearer $apiKey'});
        request.fields['model'] = 'whisper-large-v3';
        request.fields['response_format'] = 'verbose_json';
        request.fields['temperature'] = temp.toString();
        request.fields['prompt'] = finalPrompt;
        if (sttLanguage != 'auto') request.fields['language'] = sttLanguage;
        request.files.add(await http.MultipartFile.fromPath('file', audioFile.path));

        var response = await request.send().timeout(const Duration(minutes: 5));
        var responseBody = await response.stream.bytesToString();

        if (response.statusCode == 200) {
          var json = jsonDecode(responseBody);
          _log("✅ Groq STT 辨識完成！");
          await UsageTracker.addGroqSeconds(audioDurationSeconds);
          return json['segments'] ?? [];
        } else {
          throw Exception('Groq API 錯誤 (${response.statusCode}): $responseBody');
        }
      } catch (e) {
        retries--;
        if (retries == 0) rethrow;
        await Future.delayed(const Duration(seconds: 5));
      }
    }
    return [];
  }

  static Future<void> testApiKey(String apiKey) async {
    final url = Uri.parse('https://api.groq.com/openai/v1/models');
    final response = await http.get(url, headers: {'Authorization': 'Bearer $apiKey'}).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw Exception('Groq API 測試失敗 (${response.statusCode})');
  }
}

class DeepgramApi {
  static Future<List<dynamic>> transcribeAudio(String apiKey, File audioFile, String sttLanguage) async {
    final prefs = await SharedPreferences.getInstance();
    bool smartFormat = prefs.getBool('dg_smart_format') ?? false;
    bool fillerWords = prefs.getBool('dg_filler_words') ?? true;
    double uttSplit = prefs.getDouble('dg_utt_split') ?? 1.5;

    String langParam = sttLanguage == 'zh' ? 'zh-TW' : sttLanguage;
    String urlStr = 'https://api.deepgram.com/v1/listen?model=nova-2&diarize=true&utterances=true&punctuate=true';
    urlStr += '&smart_format=$smartFormat&filler_words=$fillerWords&utt_split=$uttSplit';

    if (langParam == 'auto') urlStr += '&detect_language=true';
    else urlStr += '&language=$langParam';

    var request = http.Request('POST', Uri.parse(urlStr));
    request.headers.addAll({'Authorization': 'Token $apiKey', 'Content-Type': 'audio/mp4'});
    request.bodyBytes = await audioFile.readAsBytes();

    var response = await http.Client().send(request).timeout(const Duration(minutes: 5));
    var responseBody = await response.stream.bytesToString();

    if (response.statusCode == 200 || response.statusCode == 201) {
      var json = jsonDecode(responseBody);
      return json['results']?['utterances'] ?? [];
    } else {
      throw Exception('Deepgram API 錯誤 (${response.statusCode}): $responseBody');
    }
  }

  static Future<void> testApiKey(String apiKey) async {
    final url = Uri.parse('https://api.deepgram.com/v1/projects');
    final response = await http.get(url, headers: {'Authorization': 'Token $apiKey'}).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw Exception('Deepgram API 測試失敗 (${response.statusCode})');
  }
}

class GeminiRestApi {
  static const String _baseUrl = 'https://generativelanguage.googleapis.com';

  static Future<Map<String, dynamic>> uploadFile(String apiKey, File file, String mimeType, String displayName) async {
    int fileSize = await file.length();
    _log('準備上傳音檔: $displayName (${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB)');
    final initUrl = Uri.parse('$_baseUrl/upload/v1beta/files?key=$apiKey&uploadType=resumable');
    final metadata = jsonEncode({'file': {'display_name': displayName}});

    final initResponse = await http.post(initUrl, headers: {
      'X-Goog-Upload-Protocol': 'resumable',
      'X-Goog-Upload-Command': 'start',
      'X-Goog-Upload-Header-Content-Length': fileSize.toString(),
      'X-Goog-Upload-Header-Content-Type': mimeType,
      'Content-Type': 'application/json',
    }, body: metadata);

    if (initResponse.statusCode != 200) throw Exception('Upload init failed: ${initResponse.body}');
    final uploadUrl = initResponse.headers['x-goog-upload-url'];
    if (uploadUrl == null) throw Exception('Failed to retrieve upload URL');

    final fileBytes = await file.readAsBytes();
    final uploadResponse = await http.put(Uri.parse(uploadUrl), headers: {
      'Content-Length': fileSize.toString(),
      'X-Goog-Upload-Offset': '0',
      'X-Goog-Upload-Command': 'upload, finalize',
    }, body: fileBytes);

    if (uploadResponse.statusCode != 200) throw Exception('File transfer failed: ${uploadResponse.body}');
    final responseData = jsonDecode(uploadResponse.body);
    return responseData['file'];
  }

  static Future<void> waitForFileActive(String apiKey, String fileName) async {
    final url = Uri.parse('$_baseUrl/v1beta/files/$fileName?key=$apiKey');
    int retries = 0;
    while (retries < 60) {
      final response = await http.get(url);
      if (response.statusCode != 200) throw Exception('Check status failed: ${response.body}');
      final state = jsonDecode(response.body)['state'];
      if (state == 'ACTIVE') return;
      if (state == 'FAILED') throw Exception('File processing failed');
      await Future.delayed(const Duration(seconds: 2));
      retries++;
    }
    throw Exception('Timeout waiting for file to become ACTIVE');
  }

  static Future<String> generateContent(String lockedApiKey, List<String> modelsToTry, String prompt, String fileUri, String mimeType, double audioChunkDuration) async {
    for (String currentModel in modelsToTry) {
      final url = Uri.parse('$_baseUrl/v1beta/models/$currentModel:generateContent?key=$lockedApiKey');
      int retryCount = 0;
      int maxRetries = 4;

      while (retryCount < maxRetries) {
        try {
          final response = await http.post(url, headers: {'Content-Type': 'application/json'}, body: jsonEncode({
            'contents': [{'parts': [{'text': prompt}, {'file_data': {'mime_type': mimeType, 'file_uri': fileUri}}] }],
            'generationConfig': {'responseMimeType': 'application/json'}
          })).timeout(const Duration(seconds: 120));

          if (response.statusCode == 429) {
            if (response.body.contains('RESOURCE_EXHAUSTED')) throw Exception("RESOURCE_EXHAUSTED");
            _log("⏳ API 請求頻繁，等待 15 秒...");
            await Future.delayed(const Duration(seconds: 15));
            retryCount++;
            continue;
          }
          if (response.statusCode == 404 || response.statusCode == 400) {
              _log("⚠️ 模型 $currentModel 不可用，切換備援模型...");
              break;
          }
          if (response.statusCode != 200) throw Exception('Generate failed: ${response.body}');

          await UsageTracker.addGeminiAudioSeconds(audioChunkDuration);
          return jsonDecode(response.body)['candidates'][0]['content']['parts'][0]['text'];
        } catch (e) {
          if (e.toString().contains("RESOURCE_EXHAUSTED")) rethrow;
          if (retryCount < maxRetries - 1 && !e.toString().contains('Generate failed')) {
            _log("⚠️ 網路異常 ($e)，短暫等待後重試 (${retryCount + 1}/$maxRetries)...");
            await Future.delayed(const Duration(seconds: 10));
            retryCount++;
            continue;
          } else break;
        }
      }
    }
    throw Exception('所有模型測試失敗');
  }

  static Future<String> generateTextOnly(List<String> apiKeys, List<String> modelsToTry, String prompt, {Function(String)? onWait}) async {
    for (String currentModel in modelsToTry) {
      for (int k = 0; k < apiKeys.length; k++) {
        String currentKey = apiKeys[k];
        final url = Uri.parse('$_baseUrl/v1beta/models/$currentModel:generateContent?key=$currentKey');
        int retryCount = 0;
        int maxRetries = 3;

        while (retryCount < maxRetries) {
          try {
            // 💡 1.0.62 修正：將 timeout 從 60 秒放寬至 180 秒，防止長篇翻譯時 TimeoutException
            final response = await http.post(url, headers: {'Content-Type': 'application/json'}, body: jsonEncode({
              'contents': [{'parts': [{'text': prompt}] }],
              'generationConfig': {'responseMimeType': 'application/json'}
            })).timeout(const Duration(seconds: 180));

            if (response.statusCode == 429) {
              if (response.body.contains('RESOURCE_EXHAUSTED') || response.body.contains('Quota exceeded')) {
                _log("⚠️ Key ${_maskKey(currentKey)} 額度已滿，切換下一把...");
                break;
              } else {
                if (onWait != null) onWait("請求過快，短暫休眠 15 秒...");
                _log("⏳ API 請求過於頻繁，短暫休眠 15 秒...");
                await Future.delayed(const Duration(seconds: 15));
                retryCount++;
                continue;
              }
            }
            
            if (response.statusCode == 404 || response.statusCode == 400) {
              _log("⚠️ 模型 $currentModel 不可用，切換備援模型...");
              break;
            }
            
            if (response.statusCode != 200) throw Exception('Generate failed: ${response.body}');

            await UsageTracker.addGeminiTextRequest();
            return jsonDecode(response.body)['candidates'][0]['content']['parts'][0]['text'];
          } catch (e) {
            if (retryCount < maxRetries - 1 && !e.toString().contains('Generate failed')) {
              _log("⚠️ 連線異常 ($e)，等待後重試 (${retryCount + 1}/$maxRetries)...");
              await Future.delayed(const Duration(seconds: 5));
              retryCount++;
              continue;
            } else break;
          }
        }
      }
    }
    throw Exception('所有 API Key 均已耗盡，請稍後再試。');
  }

  static Future<List<String>> getAvailableModels(String apiKey) async {
    final url = Uri.parse('$_baseUrl/v1beta/models?key=$apiKey');
    final response = await http.get(url);
    if (response.statusCode != 200) throw Exception('API 測試失敗 (${response.statusCode})');
    final data = jsonDecode(response.body);
    List<String> availableModels = [];
    for (var model in data['models'] ?? []) {
      List<dynamic> methods = model['supportedGenerationMethods'] ?? [];
      if (methods.contains('generateContent')) {
        String name = model['name'] ?? '';
        if (name.startsWith('models/')) name = name.replaceAll('models/', '');
        if (name.contains('gemini') && !name.contains('embedding')) availableModels.add(name);
      }
    }
    return availableModels;
  }
}

class GlobalManager {
  static final ValueNotifier<bool> isRecordingNotifier = ValueNotifier(false);
  static final ValueNotifier<List<String>> vocabListNotifier = ValueNotifier([]);
  static final ValueNotifier<List<String>> typoListNotifier = ValueNotifier([]); 
  static final ValueNotifier<List<String>> participantListNotifier = ValueNotifier([]);
  static final ValueNotifier<List<String>> logsNotifier = ValueNotifier([]);
  static final ValueNotifier<List<MeetingNote>> notesNotifier = ValueNotifier([]);

  static Future<List<String>> getApiKeys() async {
    final prefs = await SharedPreferences.getInstance();
    String raw = prefs.getString('api_key') ?? '';
    return raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
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
    final updatedLogs = currentLogs.length > 500 ? [newLog, ...currentLogs.take(499)] : [newLog, ...currentLogs];
    logsNotifier.value = updatedLogs;
    print(newLog);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('app_logs', updatedLogs);
  }

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    vocabListNotifier.value = prefs.getStringList('vocab_list') ?? [];
    typoListNotifier.value = prefs.getStringList('typo_list') ?? []; 
    participantListNotifier.value = prefs.getStringList('participant_list') ?? [];
    logsNotifier.value = prefs.getStringList('app_logs') ?? [];
    _log("APP 啟動 (版本: $APP_VERSION)");
    await UsageTracker.load();
    await loadNotes();
  }

  static Future<void> saveTypoList(List<String> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('typo_list', list);
    typoListNotifier.value = list;
  }

  static Future<void> loadNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      try {
        List<MeetingNote> loaded = (jsonDecode(existingJson) as List).map((e) => MeetingNote.fromJson(e)).toList();
        loaded.sort((a, b) {
          if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
          return b.date.compareTo(a.date);
        });
        notesNotifier.value = loaded;
      } catch (e) {}
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
      final newList = List<String>.from(participantListNotifier.value)..add(name);
      participantListNotifier.value = newList;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('participant_list', newList);
    }
  }

  static Future<void> removeParticipant(String name) async {
    final newList = List<String>.from(participantListNotifier.value)..remove(name);
    participantListNotifier.value = newList;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('participant_list', newList);
  }

  static Future<void> saveNote(MeetingNote note) async {
    final prefs = await SharedPreferences.getInstance();
    List<MeetingNote> notes = [];
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      try { notes = (jsonDecode(existingJson) as List).map((e) => MeetingNote.fromJson(e)).toList(); } catch (e) {}
    }
    int index = notes.indexWhere((n) => n.id == note.id);
    if (index != -1) notes[index] = note;
    else notes.add(note);
    await prefs.setString('meeting_notes', jsonEncode(notes.map((e) => e.toJson()).toList()));
    await loadNotes();
  }

  static Future<void> deleteNote(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      List<MeetingNote> notes = (jsonDecode(existingJson) as List).map((e) => MeetingNote.fromJson(e)).toList();
      final target = notes.firstWhere((n) => n.id == id, orElse: () => MeetingNote(id: '', title: '', date: DateTime.now(), audioPath: ''));
      if (target.id.isNotEmpty) {
        try {
          final f = await getActualFile(target.audioPath);
          if (await f.exists()) await f.delete();
          for (var p in target.audioParts) {
            final pf = await getActualFile(p);
            if (await pf.exists()) await pf.delete();
          }
        } catch (_) {}
      }
      notes.removeWhere((n) => n.id == id);
      await prefs.setString('meeting_notes', jsonEncode(notes.map((e) => e.toJson()).toList()));
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

  static Future<void> _updateForegroundTask(String text) async {
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.updateService(notificationTitle: 'AI 處理中 (確保網路連線)', notificationText: text);
    } else {
      await FlutterForegroundTask.startService(notificationTitle: 'AI 處理中 (確保網路連線)', notificationText: text, callback: startCallback);
    }
  }

  static Future<void> _stopForegroundTaskIfNotRecording() async {
    if (!isRecordingNotifier.value) {
      await FlutterForegroundTask.stopService();
    }
  }

  static Future<void> _saveRawSttToFile(String noteId, String content) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${noteId}_raw_stt.txt');
      await file.writeAsString(content);
    } catch (e) {
      _log("保存原始 STT 檔案失敗: $e");
    }
  }

  static Future<void> analyzeNote(MeetingNote note) async {
    await WakelockPlus.enable(); 
    note.status = NoteStatus.processing;
    note.currentStep = "準備讀取音檔...";
    _log("🔄 狀態更新: ${note.currentStep}");
    await _updateForegroundTask(note.currentStep); 
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final List<String> apiKeys = await getApiKeys();
    String strategy = prefs.getString('analysis_strategy') ?? 'flash'; 
    final String groqKey = prefs.getString('groq_api_key') ?? '';
    final String sttLanguage = prefs.getString('stt_language') ?? 'zh';
    final List<String> vocabList = vocabListNotifier.value;
    final List<String> participantList = participantListNotifier.value;

    try {
      if (apiKeys.isEmpty) throw Exception("請先設定 Gemini API Key");
      List<String> modelsToTry = strategy == 'pro' ? ['gemini-pro-latest', 'gemini-2.5-pro'] : ['gemini-flash-latest', 'gemini-2.5-flash'];
      List<String> targetParts = note.audioParts.isNotEmpty ? note.audioParts : [note.audioPath];
      double globalOffsetSeconds = 0.0;
      List<dynamic> allWhisperSegments = [];

      // ==========================================
      // STT 雙引擎模式 (Deepgram / Groq)
      // ==========================================
      if (strategy == 'groq_gemini' || strategy == 'deepgram_gemini') {
        final bool isDeepgram = strategy == 'deepgram_gemini';
        final String externalKey = isDeepgram ? (prefs.getString('deepgram_api_key') ?? '') : groqKey;
        if (externalKey.isEmpty) throw Exception("未設定 ${isDeepgram ? 'Deepgram' : 'Groq'} API Key");

        for (int i = 0; i < targetParts.length; i++) {
          final partFile = await getActualFile(targetParts[i]);
          if (!await partFile.exists()) continue;

          final tempPlayer = AudioPlayer();
          await tempPlayer.setSource(DeviceFileSource(partFile.path));
          final durationObj = await tempPlayer.getDuration();
          await tempPlayer.dispose();
          double partSecs = (durationObj?.inMilliseconds ?? 0) / 1000.0;

          if (!isDeepgram && partFile.lengthSync() / (1024 * 1024) >= 25.0) throw Exception("音檔過大，Groq 無法處理。");

          note.currentStep = "${isDeepgram ? 'Deepgram' : 'Groq'} 聽寫中 (段落 ${i + 1}/${targetParts.length})...";
          _log("🔄 狀態更新: ${note.currentStep}"); // 💡 1.0.62 修復 Log 遺失
          await _updateForegroundTask(note.currentStep);
          await saveNote(note);

          try {
            if (isDeepgram) {
              var utterances = await DeepgramApi.transcribeAudio(externalKey, partFile, sttLanguage);
              await UsageTracker.addDeepgramSeconds(partSecs); 
              for (var u in utterances) {
                allWhisperSegments.add({'start': (u['start'] as num).toDouble() + globalOffsetSeconds, 'text': u['transcript'], 'speaker': 'Speaker ${u['speaker']}'});
              }
            } else {
              var segments = await GroqApi.transcribeAudio(externalKey, partFile, partSecs, sttLanguage, vocabList);
              for (var seg in segments) {
                seg['start'] = (seg['start'] as num).toDouble() + globalOffsetSeconds;
                seg['speaker'] = 'System'; 
                allWhisperSegments.add(seg);
              }
            }
          } catch (e) {
            throw Exception("STT 引擎處理失敗: $e");
          }
          globalOffsetSeconds += partSecs;
        }

        if (allWhisperSegments.isNotEmpty) {
          List<TranscriptItem> rawTranscript = allWhisperSegments.map((seg) => TranscriptItem(speaker: seg['speaker'], original: seg['text'], startTime: seg['start'])).toList();
          note.transcript = rawTranscript;
          await saveNote(note);

          StringBuffer fullRawText = StringBuffer();
          for (var seg in allWhisperSegments) {
            fullRawText.writeln("[${seg['start']}秒] ${seg['speaker']}: ${seg['text']}");
          }
          await _saveRawSttToFile(note.id, fullRawText.toString());

          note.currentStep = "Gemini 全局摘要生成中...";
          _log("🔄 狀態更新: ${note.currentStep}");
          await _updateForegroundTask(note.currentStep);
          await saveNote(note);

          String summaryPrompt = """
          這是一份會議原始逐字稿（可能包含錯字或環境雜音）：
          ---
          $fullRawText
          ---
          請根據上述內容，整理出這場會議的「全局重點」。專有詞彙庫：${vocabList.join(', ')}。預設與會者名單：${participantList.join(', ')}。
          【極度重要輸出限制與 JSON 格式】：
          請務必精簡，並「嚴格遵守」以下 JSON 結構：
          {
            "title": "會議標題",
            "summary": ["重點1", "重點2", "重點3... (請列 5~8 點)"],
            "tasks": [{"description": "任務具體描述", "assignee": "負責人或未定", "dueDate": "期限或未定"}],
            "sections": [{"title": "段落標題", "startTime": 0, "endTime": 120}]
          }
          注意：
          - tasks: 仔細提取所有「後續行動」。如果完全沒有，請填入 [{"description": "無待辦事項", "assignee": "-", "dueDate": "-"}]。
          - sections: startTime 與 endTime 必須是純數字秒數。
          直接以 { 開始。
          """;

          try {
            final summaryResponse = await GeminiRestApi.generateTextOnly(apiKeys, modelsToTry, summaryPrompt, onWait: (msg) async {
              note.currentStep = "全局摘要生成中 - $msg";
              _log("🔄 狀態更新: ${note.currentStep}"); // 💡 修復 Log 遺失
              await _updateForegroundTask(note.currentStep);
              await saveNote(note);
            });
            final overviewJson = _parseJson(summaryResponse);
            note.title = overviewJson['title']?.toString() ?? note.title;
            var rawSummary = overviewJson['summary'];
            note.summary = rawSummary is List ? rawSummary.map((e) => e.toString()).toList() : ["摘要生成失敗"];
            note.tasks = (overviewJson['tasks'] as List<dynamic>?)?.map((e) => TaskItem.fromJson(e)).toList() ?? [];
            note.sections = (overviewJson['sections'] as List<dynamic>?)?.map((e) => Section.fromJson(e)).toList() ?? [];
            await saveNote(note);
          } catch (e) {
            _log("⚠️ 全局摘要生成失敗: $e");
            note.summary = ["【初步摘要生成失敗，系統將於逐字稿淨化完成後，自動為您重整摘要】"];
          }

          List<TranscriptItem> fullTranscript = [];
          StringBuffer currentChunk = StringBuffer();
          int batchSize = 150;
          int totalBatches = (allWhisperSegments.length / batchSize).ceil();
          int chunkCount = 0;
          List<dynamic> currentBatchSegments = [];
          String contextInfo = note.summary.join('; ');
          final List<String> typoList = typoListNotifier.value;
          String typoInstruction = typoList.isNotEmpty ? "【歷史錯字替換】：請嚴格參考此對應表(錯字 ➡️ 正確字)：${typoList.join(' , ')}" : "";

          for (var i = 0; i < allWhisperSegments.length; i++) {
            var seg = allWhisperSegments[i];
            currentChunk.writeln("[${seg['start']}秒] ${seg['speaker']}: ${seg['text']}");
            currentBatchSegments.add(seg);

            if ((i + 1) % batchSize == 0 || i == allWhisperSegments.length - 1) {
              chunkCount++;
              note.currentStep = "Gemini 講者辨識與淨化 ($chunkCount/$totalBatches)...";
              _log("🔄 狀態更新: ${note.currentStep}");
              await _updateForegroundTask(note.currentStep);
              await saveNote(note);

              String textPrompt = """
              【會議全局上下文】：$contextInfo
              專有詞彙庫：${vocabList.join(', ')}。預期與會者名單：${participantList.join(', ')}。
              以下是外部 STT 引擎產生的純文字片段：
              ---
              $currentChunk
              ---
              請扮演極度嚴格的「會議記錄淨化員」，執行以下任務：
              1. 【修復碎裂與人名校正】：將代號替換為真實人名。STT 引擎可能會切得太碎或產生空格。務必「清除所有中文字之間的空格」，將過度碎裂的短句合併成語意通順的長句！若有發音相近人名請強制校正。
              2. 【強制字典修正】：請修正錯字。
              3. 【語言與欄位填寫】：(極度重要)
                 - 若該句話是中文：將原文放 original 欄位，phonetic 與 translation 必須留空。
                 - 若該句話是外語（英日韓等）：將原文放 original 欄位，羅馬拼音放 phonetic 欄位，繁體中文翻譯放 translation 欄位。
              4. 刪除與上下文毫無關聯的外語幻覺。
              $typoInstruction
              5. 嚴格保留原始 [秒數] 填入 startTime。
              回傳純 JSON 陣列。
              """;

              try {
                final chunkResponse = await GeminiRestApi.generateTextOnly(apiKeys, modelsToTry, textPrompt);
                final List<dynamic> parsedList = _parseJsonList(chunkResponse);
                if (parsedList.isNotEmpty) {
                  fullTranscript.addAll(parsedList.map((e) => TranscriptItem.fromJson(e)).toList());
                } else throw Exception("回傳了空陣列");
              } catch (e) {
                _log("⚠️ 淨化失敗: $e");
                fullTranscript.addAll(currentBatchSegments.map((s) => TranscriptItem(speaker: s['speaker'], original: s['text'], startTime: s['start'])).toList());
              }
              currentChunk.clear();
              currentBatchSegments.clear();
            }
          }
          if (fullTranscript.isNotEmpty) note.transcript = fullTranscript;
          await saveNote(note);

          if (note.summary.isNotEmpty && note.summary[0].contains("失敗")) {
             note.currentStep = "逐字稿已完成，正在補成全局摘要...";
             _log("🔄 狀態更新: ${note.currentStep}");
             await _updateForegroundTask(note.currentStep);
             await reSummarizeFromTranscript(note);
          } else {
             note.status = NoteStatus.success;
             note.currentStep = '';
             await saveNote(note);
             _log("分析完成！");
          }
          return;
        }
      }

      // ==========================================
      // 原生 Gemini 聽寫模式 (Flash / Pro)
      // ==========================================
      if (strategy != 'groq_gemini') {
        modelsToTry = strategy == 'pro' ? ['gemini-pro-latest', 'gemini-2.5-pro'] : ['gemini-flash-latest', 'gemini-2.5-flash'];
        int currentKeyIndex = 0;
        String lockedKey = apiKeys[currentKeyIndex];
        final audioFile = await getActualFile(targetParts.isNotEmpty ? targetParts.first : note.audioPath);
        final tempPlayer = AudioPlayer();
        await tempPlayer.setSource(DeviceFileSource(audioFile.path));
        final duration = await tempPlayer.getDuration();
        await tempPlayer.dispose();
        double totalSeconds = (duration?.inMilliseconds ?? 0) / 1000.0;
        
        int chunkSize = strategy == 'pro' ? 120 : 200; 
        if (totalSeconds <= 0) totalSeconds = chunkSize * 36.0;
        int maxChunks = (totalSeconds / chunkSize).ceil();
        if (maxChunks == 0) maxChunks = 1;

        note.currentStep = "上傳大型音訊檔案中...";
        _log("🔄 狀態更新: ${note.currentStep}");
        await _updateForegroundTask(note.currentStep);
        await saveNote(note);

        var fileInfo = await GeminiRestApi.uploadFile(lockedKey, audioFile, 'audio/mp4', note.title);
        String fileUri = fileInfo['uri'];
        await GeminiRestApi.waitForFileActive(lockedKey, fileInfo['name'].split('/').last);

        note.currentStep = "AI 正在分析會議摘要...";
        _log("🔄 狀態更新: ${note.currentStep}");
        await _updateForegroundTask(note.currentStep);
        await saveNote(note);

        String overviewPrompt = """
        這是一場會議的完整錄音。請根據音訊內容，整理出全局重點。
        專有詞彙庫：${vocabList.join(', ')}。預設與會者名單：${participantList.join(', ')}。
        【極度重要輸出限制與 JSON 格式】：
        請務必精簡，並「嚴格遵守」以下 JSON Key 的命名與陣列結構：
        {
          "title": "會議標題",
          "summary": ["重點1", "重點2", "重點3... (請列 5~8 點)"],
          "tasks": [{"description": "任務具體描述", "assignee": "負責人或未定", "dueDate": "期限或未定"}],
          "sections": [{"title": "段落標題", "startTime": 0, "endTime": 120}]
        }
        注意：
        - tasks: 仔細提取後續行動。如果完全沒有，請填入 [{"description": "無待辦事項", "assignee": "-", "dueDate": "-"}]。
        - sections: startTime 與 endTime 必須是純數字秒數。
        不要加上 ```json 標籤，直接以 { 開始。
        """;

        try {
          final overviewResponseText = await GeminiRestApi.generateContent(lockedKey, modelsToTry, overviewPrompt, fileUri, 'audio/mp4', totalSeconds);
          final overviewJson = _parseJson(overviewResponseText);
          note.title = overviewJson['title']?.toString() ?? note.title;
          var rawSummary = overviewJson['summary'];
          note.summary = rawSummary is List ? rawSummary.map((e) => e.toString()).toList() : ["摘要生成失敗"];
          note.tasks = (overviewJson['tasks'] as List<dynamic>?)?.map((e) => TaskItem.fromJson(e)).toList() ?? [];
          note.sections = (overviewJson['sections'] as List<dynamic>?)?.map((e) => Section.fromJson(e)).toList() ?? [];
        } catch (e) {
          _log("摘要產生遇到問題: $e");
          note.summary = ["【初步摘要生成失敗，系統將於逐字稿聽打完成後，自動為您重整摘要】"];
        }

        List<TranscriptItem> fullTranscript = [];
        String contextInfo = note.summary.join('; ');
        final List<String> typoList = typoListNotifier.value;
        String typoInstruction = typoList.isNotEmpty ? "【歷史錯字替換】：請嚴格參考此對應表(錯字 ➡️ 正確字)：${typoList.join(' , ')}" : "";
        String previousContext = "";

        for (int i = 0; i < maxChunks; i++) {
          note.currentStep = "原生語音聽打 (${i + 1}/$maxChunks)...";
          _log("🔄 狀態更新: ${note.currentStep}");
          await _updateForegroundTask(note.currentStep);
          await saveNote(note);

          double chunkStart = (i * chunkSize).toDouble();
          double chunkEnd = ((i + 1) * chunkSize).toDouble();
          double thisChunkDuration = chunkEnd > totalSeconds ? (totalSeconds - chunkStart) : chunkSize.toDouble();

          String transcriptPrompt = """
          請扮演極度專業的「會議記錄聽打員」。這是一份長音檔，請你【嚴格且只針對】第 $chunkStart 秒 到第 $chunkEnd 秒的音訊片段提供逐字稿。
          【會議全局上下文】：$contextInfo
          專有詞彙庫：${vocabList.join(', ')}。預期與會者名單：${participantList.join(', ')}。
          
          ${previousContext.isNotEmpty ? '【前情提要】：上一段最後的對話是：「\n$previousContext\n」。\n請從這句話「之後」接續聽打，絕對不要重複前情提要的內容！' : ''}

          【極度重要限制】：
          1. 絕對不可從 0 秒開始聽打！精準從第 $chunkStart 秒開始，到第 $chunkEnd 秒結束。
          2. 如果這段時間內是「靜音」或無人說話，請直接回傳空陣列 []。
          3. 【時間戳】：startTime 必須大於等於 $chunkStart。如果發現你打出的時間是 0，代表你聽錯段落了，請重新對齊時間！
          4. 單一句子長度超過 10 秒必須斷開。
          5. 【講者辨識】：請根據聲音特徵與「全局上下文」，精準標註講者。
          $typoInstruction
          請直接回傳純 JSON 陣列。
          """;

          bool chunkSuccess = false;
          int emptyCount = 0;
          while (!chunkSuccess) {
            try {
              final chunkResponseText = await GeminiRestApi.generateContent(lockedKey, modelsToTry, transcriptPrompt, fileUri, 'audio/mp4', thisChunkDuration);
              final List<dynamic> chunkList = _parseJsonList(chunkResponseText);
              if (chunkList.isEmpty) {
                emptyCount++;
                if (emptyCount >= 2) break;
              } else {
                emptyCount = 0;
                var newItems = chunkList.map((e) => TranscriptItem.fromJson(e)).toList();
                
                newItems.removeWhere((item) => item.startTime < (chunkStart - 15.0) || item.startTime > (chunkEnd + 30.0));
                
                if (newItems.isNotEmpty) {
                  fullTranscript.addAll(newItems);
                  var lastItems = newItems.length > 2 ? newItems.sublist(newItems.length - 2) : newItems;
                  previousContext = lastItems.map((e) => "[${e.startTime}秒] ${e.speaker}: ${e.original}").join('\n');
                }
              }
              chunkSuccess = true;
            } catch (e) {
              if (e.toString().contains("RESOURCE_EXHAUSTED") || e.toString().contains("Quota")) {
                currentKeyIndex++;
                if (currentKeyIndex >= apiKeys.length) throw Exception("所有 API Key 均已耗盡！");
                lockedKey = apiKeys[currentKeyIndex];
                _log("🔄 額度滿載！無縫切換 Key，重傳音檔中...");
                fileInfo = await GeminiRestApi.uploadFile(lockedKey, audioFile, 'audio/mp4', note.title);
                fileUri = fileInfo['uri'];
                await GeminiRestApi.waitForFileActive(lockedKey, fileInfo['name'].split('/').last);
              } else {
                _log("分段 $i 失敗: $e");
                chunkSuccess = true; 
              }
            }
          }
        }
        
        note.transcript = fullTranscript;
        await saveNote(note);
        
        StringBuffer rawTextBuffer = StringBuffer();
        for (var item in fullTranscript) { rawTextBuffer.writeln("[${item.startTime}秒] ${item.speaker}: ${item.original}"); }
        await _saveRawSttToFile(note.id, rawTextBuffer.toString());

        if (note.summary.isNotEmpty && note.summary[0].contains("失敗")) {
             note.currentStep = "逐字稿已完成，正在補成全局摘要...";
             _log("🔄 狀態更新: ${note.currentStep}");
             await _updateForegroundTask(note.currentStep);
             await reSummarizeFromTranscript(note);
        } else {
             note.status = NoteStatus.success;
             note.currentStep = '';
             await saveNote(note);
             _log("分析完成！");
        }
      }
    } catch (e) {
      _log("分析流程錯誤: $e");
      note.status = NoteStatus.failed;
      note.summary = ["分析失敗: $e"];
      note.currentStep = '';
      await saveNote(note);
    } finally {
      await WakelockPlus.disable(); 
      await _stopForegroundTaskIfNotRecording(); 
    }
  }

  static Future<void> reCalibrateTranscript(MeetingNote note) async {
    await WakelockPlus.enable(); 
    note.status = NoteStatus.processing;
    note.currentStep = "準備校正逐字稿...";
    _log("🔄 狀態更新: ${note.currentStep}");
    await _updateForegroundTask(note.currentStep);
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final List<String> apiKeys = await getApiKeys();
    final String strategy = prefs.getString('analysis_strategy') ?? 'flash';
    final List<String> vocabList = vocabListNotifier.value;
    final List<String> participantList = participantListNotifier.value;

    try {
      if (apiKeys.isEmpty) throw Exception("請先設定 API Key");
      if (note.transcript.isEmpty) throw Exception("沒有可用的逐字稿。");

      List<String> modelsToTry = strategy == 'pro' ? ['gemini-pro-latest', 'gemini-2.5-pro'] : ['gemini-flash-latest', 'gemini-2.5-flash'];
      List<TranscriptItem> calibratedTranscript = [];
      int totalItems = note.transcript.length;
      int batchSize = 150;
      int totalBatches = (totalItems / batchSize).ceil();
      String contextInfo = note.summary.join('; ');
      final List<String> typoList = typoListNotifier.value;
      String typoInstruction = typoList.isNotEmpty ? "【歷史錯字替換】：請嚴格參考此對應表(錯字 ➡️ 正確字)：${typoList.join(' , ')}" : "";

      for (int i = 0; i < totalBatches; i++) {
        int startIdx = i * batchSize;
        int endIdx = min((i + 1) * batchSize, totalItems);
        var batchItems = note.transcript.sublist(startIdx, endIdx);

        note.currentStep = "AI 正在校正錯字與講者 (${i + 1}/$totalBatches)...";
        _log("🔄 狀態更新: ${note.currentStep}");
        await _updateForegroundTask(note.currentStep);
        await saveNote(note);

        StringBuffer currentChunk = StringBuffer();
        for (var item in batchItems) {
          currentChunk.writeln("[${item.startTime}秒] ${item.speaker}: ${item.original}");
        }

        String textPrompt = """
        這是一場會議的局部逐字稿。
        【會議全局上下文】：$contextInfo
        以下是現有的逐字稿：
        ---
        $currentChunk
        ---
        請扮演極度嚴格的「會議記錄淨化員」，執行以下任務：
        1. 【修復碎裂與幻覺過濾】：請掃描並「整句刪除」毫無意義的外語亂碼幻覺。同時，務必「清除所有中文字之間的不正常空格」，並將過度碎裂的短句合併成流暢的長句。參考詞彙庫：${vocabList.join(', ')}。
        2. 參考最新與會者名單：${participantList.join(', ')}。根據上下文語意重新判斷說話者。並強制修正人名錯字。
        $typoInstruction
        3. 【極度重要】：絕對嚴格保留原始括號內的 [秒數] 填入 startTime！
        4. 【語言與欄位填寫】：(極度重要)
           - 若該句話是中文：將原文放 original 欄位，phonetic 與 translation 必須留空。
           - 若該句話是外語（英日韓等）：將原文放 original 欄位，羅馬拼音放 phonetic 欄位，繁體中文翻譯放 translation 欄位。
        請回傳純 JSON 陣列。
        """;

        try {
          final chunkResponse = await GeminiRestApi.generateTextOnly(apiKeys, modelsToTry, textPrompt);
          final List<dynamic> parsedList = _parseJsonList(chunkResponse);
          if (parsedList.isNotEmpty) {
            calibratedTranscript.addAll(parsedList.map((e) => TranscriptItem.fromJson(e)).toList());
          }
        } catch (e) {
          _log("⚠️ 校正失敗，保留原始內容: $e");
          calibratedTranscript.addAll(batchItems);
        }
      }

      note.transcript = calibratedTranscript;
      await saveNote(note);

      note.currentStep = "正在重整最終摘要...";
      _log("🔄 狀態更新: ${note.currentStep}");
      await _updateForegroundTask(note.currentStep);
      await saveNote(note);
      await reSummarizeFromTranscript(note);
    } catch (e) {
      _log("校正發生錯誤: $e");
      note.status = NoteStatus.failed;
      note.summary.insert(0, "校正失敗: $e");
      note.currentStep = '';
      await saveNote(note);
    } finally {
      await WakelockPlus.disable(); 
      await _stopForegroundTaskIfNotRecording();
    }
  }

  static Future<void> reSummarizeFromTranscript(MeetingNote note) async {
    await WakelockPlus.enable(); 
    note.status = NoteStatus.processing;
    note.currentStep = "基於最新逐字稿重整摘要...";
    _log("🔄 狀態更新: ${note.currentStep}");
    await _updateForegroundTask(note.currentStep);
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final List<String> apiKeys = await getApiKeys();
    final String strategy = prefs.getString('analysis_strategy') ?? 'flash';

    try {
      if (apiKeys.isEmpty) throw Exception("請先設定 API Key");
      List<String> modelsToTry = strategy == 'pro' ? ['gemini-pro-latest', 'gemini-2.5-pro'] : ['gemini-flash-latest', 'gemini-2.5-flash'];
      
      double totalSeconds = 0.0;
      List<String> paths = note.audioParts.isNotEmpty ? note.audioParts : [note.audioPath];
      for (String p in paths) {
        if (p.isEmpty) continue;
        File f = await getActualFile(p);
        if (await f.exists()) {
          final tempP = AudioPlayer();
          await tempP.setSource(DeviceFileSource(f.path));
          final d = await tempP.getDuration();
          totalSeconds += (d?.inMilliseconds ?? 0) / 1000.0;
          await tempP.dispose();
        }
      }
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
      【嚴格限制與 JSON 格式】：
      1. 內容必須 100% 來自上方文字，絕對禁止腦補！
      2. 請「嚴格遵守」以下 JSON 結構：
      {
        "title": "會議標題",
        "summary": ["重點1", "重點2", "重點3... (請列 5~8 點)"],
        "tasks": [{"description": "任務具體描述", "assignee": "負責人或未定", "dueDate": "期限或未定"}],
        "sections": [{"title": "段落標題", "startTime": 12.5, "endTime": 45.0}]
      }
      3. tasks (待辦事項): 提取所有後續行動。如果完全沒有，請填入 [{"description": "無待辦事項", "assignee": "-", "dueDate": "-"}]。
      4. sections (會議段落): startTime 與 endTime 必須是純數字秒數。
      請直接回傳純 JSON 格式。
      """;

      final responseText = await GeminiRestApi.generateTextOnly(apiKeys, modelsToTry, prompt, onWait: (msg) async {
        note.currentStep = "重整摘要中 - $msg";
        _log("🔄 狀態更新: ${note.currentStep}"); // 💡 修復 Log 遺失
        await _updateForegroundTask(note.currentStep);
        await saveNote(note);
      });

      final overviewJson = _parseJson(responseText);
      note.title = overviewJson['title']?.toString() ?? note.title;
      var rawSummary = overviewJson['summary'];
      note.summary = rawSummary is List ? rawSummary.map((e) => e.toString()).toList() : ["無法生成摘要"];
      note.tasks = (overviewJson['tasks'] as List<dynamic>?)?.map((e) => TaskItem.fromJson(e)).toList() ?? [];
      note.sections = (overviewJson['sections'] as List<dynamic>?)?.map((e) => Section.fromJson(e)).toList() ?? [];

      for (var sec in note.sections) {
        if (sec.endTime > totalSeconds) sec.endTime = totalSeconds;
        if (sec.startTime > totalSeconds) sec.startTime = totalSeconds - 1;
      }
      note.status = NoteStatus.success;
      note.currentStep = '';
      _log("✅ 基於逐字稿重整摘要成功！");
      await saveNote(note);
    } catch (e) {
      _log("❌ 重分析失敗: $e");
      note.status = NoteStatus.failed;
      note.summary = ["重新摘要失敗: $e"];
      note.currentStep = '';
      await saveNote(note);
    } finally {
      await WakelockPlus.disable();
      await _stopForegroundTaskIfNotRecording();
    }
  }

  static Future<void> translateTranscript(MeetingNote note, String targetLang) async {
    await WakelockPlus.enable(); 
    note.status = NoteStatus.processing;
    note.currentStep = "準備翻譯逐字稿...";
    _log("🔄 狀態更新: ${note.currentStep}");
    await _updateForegroundTask(note.currentStep);
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final List<String> apiKeys = await getApiKeys();
    final String strategy = prefs.getString('analysis_strategy') ?? 'flash';

    try {
      if (apiKeys.isEmpty) throw Exception("請先設定 API Key");
      if (note.transcript.isEmpty) throw Exception("逐字稿為空，無法翻譯");

      List<String> modelsToTry = strategy == 'pro' ? ['gemini-pro-latest', 'gemini-2.5-pro'] : ['gemini-flash-latest', 'gemini-2.5-flash'];
      String langName = "";
      String phoneticInstruction = "";
      if (targetLang == 'en') { langName = "英文 (English)"; phoneticInstruction = "phonetic 欄位請留空。"; }
      else if (targetLang == 'ja') { langName = "日文 (日本語)"; phoneticInstruction = "phonetic 欄位請務必提供「羅馬拼音 (Romaji)」。"; }
      else if (targetLang == 'ko') { langName = "韓文 (한국어)"; phoneticInstruction = "phonetic 欄位請務必提供「羅馬拼音 (Romaja)」。"; }
      else if (targetLang == 'zh') { langName = "繁體中文"; phoneticInstruction = "phonetic 欄位請提供「漢語拼音」。"; }

      // 💡 1.0.62 修正：縮小翻譯批次大小至 40，防止超時
      int batchSize = 40;
      int totalBatches = (note.transcript.length / batchSize).ceil();

      for (int i = 0; i < totalBatches; i++) {
        int startIdx = i * batchSize;
        int endIdx = min((i + 1) * batchSize, note.transcript.length);
        var batchItems = note.transcript.sublist(startIdx, endIdx);

        note.currentStep = "AI 正在翻譯為 $langName (${i + 1}/$totalBatches)...";
        _log("🔄 狀態更新: ${note.currentStep}");
        await _updateForegroundTask(note.currentStep);
        await saveNote(note);

        StringBuffer currentChunk = StringBuffer();
        for (var item in batchItems) {
          currentChunk.writeln("[${item.startTime}秒] ${item.speaker}: ${item.original}");
        }

        String textPrompt = """
        請將以下會議逐字稿內容，翻譯為「$langName」。
        ---
        $currentChunk
        ---
        【嚴格限制與 JSON 格式】：
        1. 絕對不可刪減或合併句子，輸入有幾句，輸出就必須有幾句。
        2. 請將原文保留在 `original` 欄位。
        3. 請將翻譯結果填入 `translation` 欄位。
        4. $phoneticInstruction
        5. 嚴格保留原始 [秒數] 填入 startTime 欄位，說話者填入 speaker 欄位。
        請直接回傳純 JSON 陣列。
        """;

        try {
          final chunkResponse = await GeminiRestApi.generateTextOnly(apiKeys, modelsToTry, textPrompt);
          final List<dynamic> parsedList = _parseJsonList(chunkResponse);
          if (parsedList.isNotEmpty) {
            for (var p in parsedList) {
              var tItem = TranscriptItem.fromJson(p);
              var matchIdx = batchItems.indexWhere((b) => (b.startTime - tItem.startTime).abs() < 0.1);
              if (matchIdx != -1) {
                note.transcript[startIdx + matchIdx].translation = tItem.translation;
                note.transcript[startIdx + matchIdx].phonetic = tItem.phonetic;
              }
            }
          }
        } catch (e) {
          _log("⚠️ 第 ${i + 1} 批次翻譯失敗: $e");
        }
      }

      note.status = NoteStatus.success;
      note.currentStep = '';
      _log("✅ 逐字稿翻譯完成 ($langName)");
      await saveNote(note);
    } catch (e) {
      _log("❌ 翻譯流程錯誤: $e");
      note.status = NoteStatus.failed;
      note.summary.insert(0, "翻譯失敗: $e");
      note.currentStep = '';
      await saveNote(note);
    } finally {
      await WakelockPlus.disable(); 
      await _stopForegroundTaskIfNotRecording();
    }
  }

  static Future<void> reListenSegment(MeetingNote note, int targetIndex, String targetLang) async {
    await WakelockPlus.enable();
    note.status = NoteStatus.processing;
    note.currentStep = "正在局部重聽 (指定語系)...";
    _log("🔄 狀態更新: ${note.currentStep}");
    await _updateForegroundTask(note.currentStep);
    await saveNote(note);

    try {
      final prefs = await SharedPreferences.getInstance();
      final String externalKey = prefs.getString('deepgram_api_key') ?? '';
      if (externalKey.isEmpty) throw Exception("請先設定 Deepgram API Key");

      double targetTime = note.transcript[targetIndex].startTime;
      double windowStart = max(0.0, targetTime - 5.0);
      double windowEnd = targetTime + 45.0; 

      List<String> targetParts = note.audioParts.isNotEmpty ? note.audioParts : [note.audioPath];
      double currentOffset = 0.0;
      File? targetFile;
      double partOffset = 0.0;
      double partDuration = 0.0;

      for (String p in targetParts) {
        File f = await getActualFile(p);
        if (!await f.exists()) continue;
        final tempPlayer = AudioPlayer();
        await tempPlayer.setSource(DeviceFileSource(f.path));
        final durationObj = await tempPlayer.getDuration();
        await tempPlayer.dispose();
        double partSecs = (durationObj?.inMilliseconds ?? 0) / 1000.0;

        if (targetTime >= currentOffset && targetTime <= currentOffset + partSecs) {
          targetFile = f;
          partOffset = currentOffset;
          partDuration = partSecs;
          break;
        }
        currentOffset += partSecs;
      }

      if (targetFile == null) throw Exception("找不到對應的音檔片段");

      var utterances = await DeepgramApi.transcribeAudio(externalKey, targetFile, targetLang);
      await UsageTracker.addDeepgramSeconds(partDuration); 

      List<dynamic> filteredUtterances = [];
      for (var u in utterances) {
        double start = (u['start'] as num).toDouble() + partOffset;
        if (start >= windowStart && start <= windowEnd) {
          filteredUtterances.add({'start': start, 'text': u['transcript'], 'speaker': 'Speaker ${u['speaker']}'});
        }
      }

      if (filteredUtterances.isEmpty) throw Exception("該區段沒有辨識出聲音");

      StringBuffer sb = StringBuffer();
      for (var u in filteredUtterances) {
        sb.writeln("[${u['start']}秒] ${u['speaker']}: ${u['text']}");
      }

      String prompt = """
      這是一段局部的重新聽寫稿（目標語系：$targetLang）。
      請扮演極度嚴格的「會議記錄淨化員」，執行以下任務：
      1. 【修復過度碎裂】：請務必「清除所有中文字之間的空格」，並將過度碎裂的短句合併成語意通順的長句！
      2. 【語言與翻譯】：如果原文是外語，放 original 欄位，羅馬拼音放 phonetic，繁體中文翻譯放 translation。中文則其餘留空。
      3. 嚴格保留原始 [秒數] 填入 startTime。

      以下是原始 STT 內容：
      ---
      $sb
      ---
      回傳純 JSON 陣列。
      """;

      final apiKeys = await getApiKeys();
      String strategy = prefs.getString('analysis_strategy') ?? 'flash';
      List<String> modelsToTry = strategy == 'pro' ? ['gemini-pro-latest', 'gemini-2.5-pro'] : ['gemini-flash-latest', 'gemini-2.5-flash'];

      final response = await GeminiRestApi.generateTextOnly(apiKeys, modelsToTry, prompt);
      final List<dynamic> parsedList = _parseJsonList(response);
      List<TranscriptItem> newItems = parsedList.map((e) => TranscriptItem.fromJson(e)).toList();

      if (newItems.isNotEmpty) {
        note.transcript.removeWhere((item) => item.startTime >= windowStart && item.startTime <= windowEnd);
        note.transcript.addAll(newItems);
        note.transcript.sort((a, b) => a.startTime.compareTo(b.startTime));
      } else {
        throw Exception("AI 處理後回傳空白");
      }

      note.status = NoteStatus.success;
      note.currentStep = '';
      await saveNote(note);

    } catch (e) {
      _log("❌ 局部重聽失敗: $e");
      note.status = NoteStatus.failed;
      note.summary.insert(0, "局部重聽失敗: $e");
      note.currentStep = '';
      await saveNote(note);
    } finally {
      await WakelockPlus.disable();
      await _stopForegroundTaskIfNotRecording();
    }
  }

  static Map<String, dynamic> _parseJson(String? text) {
    if (text == null) return {};
    try {
      String cleanText = text.trim();
      if (cleanText.startsWith('```json')) cleanText = cleanText.substring(7);
      else if (cleanText.startsWith('```')) cleanText = cleanText.substring(3);
      if (cleanText.endsWith('```')) cleanText = cleanText.substring(0, cleanText.length - 3);
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
      if (cleanText.startsWith('```json')) cleanText = cleanText.substring(7);
      else if (cleanText.startsWith('```')) cleanText = cleanText.substring(3);
      if (cleanText.endsWith('```')) cleanText = cleanText.substring(0, cleanText.length - 3);
      final result = jsonDecode(cleanText.trim());
      if (result is List) return result;
      if (result is Map && result.containsKey('transcript') && result['transcript'] is List) return result['transcript'];
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

class _MainAppShellState extends State<MainAppShell> with WidgetsBindingObserver {
  int currentIndex = 0;
  final AudioRecorder audioRecorder = AudioRecorder();
  final Stopwatch stopwatch = Stopwatch();
  Timer? timer;
  String timerText = "00:00";
  int recordingPart = 1;
  DateTime? recordingSessionStartTime;
  bool _isSystemInterrupted = false;
  bool _isRecovering = false;
  int _deadMicCounter = 0;
  double _lastAmplitude = 0.0;
  int _frozenMicCounter = 0;
  bool _isAppInForeground = true;
  List<String> _sessionAudioParts = [];
  bool _isWaitingForUserResume = false;
  final List<Widget> pages = [const HomePage(), const SettingsPage()];
  AppLifecycleState? _lastLifecycleState; 

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initForegroundTask();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'recording_channel',
        channelName: '會議錄音背景服務',
        channelDescription: '保持麥克風與網路在背景持續運作不中斷',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
        iconData: const NotificationIconData(resType: ResourceType.mipmap, resPrefix: ResourcePrefix.ic, name: 'launcher'),
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: false),
      foregroundTaskOptions: const ForegroundTaskOptions(interval: 5000, isOnceEvent: false, autoRunOnBoot: false, allowWakeLock: true, allowWifiLock: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    audioRecorder.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_lastLifecycleState == state) return; 
    _lastLifecycleState = state;
    setState(() => _isAppInForeground = state == AppLifecycleState.resumed);
    if (GlobalManager.isRecordingNotifier.value) {
      if (state == AppLifecycleState.resumed) GlobalManager.addLog("📱 [生命週期] APP 回到前景 (Resumed)");
      else GlobalManager.addLog("📱 [生命週期] APP 進入背景 ($state)");
    }
  }

  void toggleRecording() async {
    if (GlobalManager.isRecordingNotifier.value) await stopAndAnalyze(manualStop: true);
    else { recordingPart = 1; recordingSessionStartTime = DateTime.now(); await startRecording(); }
  }

  Future<void> startRecording() async {
    Map<Permission, PermissionStatus> statuses = await [Permission.microphone, Permission.notification].request();
    if (statuses[Permission.microphone]!.isGranted) {
      if (await FlutterForegroundTask.isRunningService == false) {
        await FlutterForegroundTask.startService(notificationTitle: '會議錄音中', notificationText: 'APP 正在背景安全地為您錄製會議...', callback: startCallback);
      }
      final session = await as_lib.AudioSession.instance;
      await session.configure(as_lib.AudioSessionConfiguration(
        avAudioSessionCategory: as_lib.AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions: as_lib.AVAudioSessionCategoryOptions.allowBluetooth | as_lib.AVAudioSessionCategoryOptions.defaultToSpeaker | as_lib.AVAudioSessionCategoryOptions.mixWithOthers,
        androidAudioAttributes: as_lib.AndroidAudioAttributes(contentType: as_lib.AndroidAudioContentType.speech, flags: as_lib.AndroidAudioFlags.none, usage: as_lib.AndroidAudioUsage.media),
        androidWillPauseWhenDucked: false,
      ));
      await session.setActive(true);

      final dir = await getApplicationDocumentsDirectory();
      final fileName = "rec_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}_p$recordingPart.m4a";
      final path = '${dir.path}/$fileName';

      _isSystemInterrupted = false; _deadMicCounter = 0; _sessionAudioParts = [];

      await audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 16000, numChannels: 1, autoGain: true, echoCancel: true, noiseSuppress: true), path: path);
      stopwatch.reset(); stopwatch.start();
      GlobalManager.addLog("🎙️ 開始錄音 (Part $recordingPart)...");

      timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted || _isRecovering) return;
        bool isStillRecording = await audioRecorder.isRecording();
        bool isMicDead = false;

        if (isStillRecording && !_isSystemInterrupted) {
          try {
            final amp = await audioRecorder.getAmplitude();
            double currentAmp = amp.current;
            if (currentAmp == _lastAmplitude && currentAmp < -10.0) _frozenMicCounter++; else _frozenMicCounter = 0;
            if (currentAmp <= -100.0) _deadMicCounter++; else _deadMicCounter = 0;
            _lastAmplitude = currentAmp;
            if ((_deadMicCounter >= 3 || _frozenMicCounter >= 3) && !_isAppInForeground) isMicDead = true;
          } catch (_) {}
        }

        if ((!isStillRecording || isMicDead) && GlobalManager.isRecordingNotifier.value) {
          if (!_isSystemInterrupted) {
            _isSystemInterrupted = true;
            GlobalManager.addLog("⚠️ 系統奪取麥克風！觸發時分貝: ${_lastAmplitude.toStringAsFixed(2)} dB");
            _deadMicCounter = 0; _frozenMicCounter = 0; _lastAmplitude = 0.0;
            stopwatch.stop();
            GlobalManager.addLog("⚠️ 錄音被系統奪取！等待您點擊 APP 恢復...");
            FlutterForegroundTask.updateService(notificationTitle: '⚠️ 錄音已暫停', notificationText: '請點擊回到 APP 以繼續錄音');
            try {
              final path = await audioRecorder.stop();
              if (path != null && stopwatch.elapsed.inSeconds >= 2) _sessionAudioParts.add(path);
              else if (path != null) File(path).delete().catchError((_) {});
            } catch (e) {}
            recordingPart++; _isWaitingForUserResume = true;
          } else {
            if (_isAppInForeground && _isWaitingForUserResume) {
              _isRecovering = true; _isWaitingForUserResume = false;
              try {
                GlobalManager.addLog("🔄 歡迎回來！嘗試恢復錄音...");
                final session = await as_lib.AudioSession.instance;
                await session.setActive(true);
                final dir = await getApplicationDocumentsDirectory();
                final resumePath = '${dir.path}/rec_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}_p$recordingPart.m4a';
                await audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 16000, numChannels: 1, autoGain: true, echoCancel: true, noiseSuppress: true), path: resumePath);
                await Future.delayed(const Duration(seconds: 1));
                if (await audioRecorder.isRecording()) {
                  _isSystemInterrupted = false; _deadMicCounter = 0; _frozenMicCounter = 0; _lastAmplitude = 0.0;
                  stopwatch.start();
                  GlobalManager.addLog("✅ 成功接續錄音 (內部 Part $recordingPart)");
                  FlutterForegroundTask.updateService(notificationTitle: '會議錄音中', notificationText: '已恢復錄製 (總計 $timerText)');
                } else {
                  await audioRecorder.stop();
                  GlobalManager.addLog("❌ 恢復失敗，請確認已關閉通話或其他聲音來源。");
                  _isWaitingForUserResume = true; 
                }
              } catch (e) { _isWaitingForUserResume = true; } finally { _isRecovering = false; }
            }
          }
          return;
        }

        setState(() { timerText = "${stopwatch.elapsed.inMinutes.toString().padLeft(2, '0')}:${(stopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}"; });
        if (stopwatch.elapsed.inMinutes >= 60 && !_isSystemInterrupted) await handleAutoSplit();
      });

      GlobalManager.isRecordingNotifier.value = true;
      await WakelockPlus.enable();
    } else {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("需要麥克風權限才能錄音")));
    }
  }

  Future<void> handleAutoSplit() async {
    timer?.cancel();
    final path = await audioRecorder.stop();
    stopwatch.stop();
    if (path != null) {
      String title = "會議錄音 Part $recordingPart";
      if (recordingSessionStartTime != null) title += " (${DateFormat('HH:mm').format(recordingSessionStartTime!)})";
      createNewNoteAndAnalyze([path], title, date: DateTime.now());
    }
    recordingPart++;
    await startRecording();
  }

  Future<void> stopAndAnalyze({bool manualStop = false}) async {
    timer?.cancel();
    String? path;
    try { path = await audioRecorder.stop(); } catch (_) {}
    stopwatch.stop();
    GlobalManager.isRecordingNotifier.value = false;
    
    await WakelockPlus.disable();

    if (path != null && !_isSystemInterrupted && stopwatch.elapsed.inSeconds >= 2) _sessionAudioParts.add(path);
    else if (path != null && _isSystemInterrupted) File(path).delete().catchError((_) {});

    if (_sessionAudioParts.isNotEmpty) {
      String title = manualStop && recordingPart == 1 ? "會議錄音" : "會議錄音 (${DateFormat('HH:mm').format(recordingSessionStartTime ?? DateTime.now())})";
      createNewNoteAndAnalyze(List.from(_sessionAudioParts), title, date: DateTime.now());
    }

    setState(() { timerText = "00:00"; _isSystemInterrupted = false; _isRecovering = false; _isWaitingForUserResume = false; _deadMicCounter = 0; _frozenMicCounter = 0; _lastAmplitude = 0.0; _sessionAudioParts = []; });
  }

  void createNewNoteAndAnalyze(List<String> paths, String defaultTitle, {required DateTime date}) async {
    final newNote = MeetingNote(
      id: const Uuid().v4(),
      title: "$defaultTitle (${DateFormat('yyyy/MM/dd').format(date)})",
      date: date,
      summary: ["AI 分析中..."],
      audioPath: paths.isNotEmpty ? paths.first : "", 
      audioParts: paths, 
      status: NoteStatus.processing,
    );
    await GlobalManager.saveNote(newNote);
    GlobalManager.analyzeNote(newNote);
    GlobalManager.addLog("🛑 結束並儲存錄音，開始無縫背景分析...");
    if (mounted) setState(() {});
  }

  Future<void> pickFile() async {
    Map<Permission, PermissionStatus> statuses = await [Permission.storage, Permission.audio, Permission.mediaLibrary].request();
    if (statuses.values.any((s) => s.isGranted || s.isLimited) || await Permission.storage.isGranted) {
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio);
      if (result != null) {
        File file = File(result.files.single.path!);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("正在準備上傳檔案..."), backgroundColor: Colors.blue));
        DateTime fileDate = DateTime.now();
        try {
          String fileName = result.files.single.name;
          RegExp regExp = RegExp(r'(20\d{2})[-_]?(\d{2})[-_]?(\d{2})[-_]?(\d{2})[-_]?(\d{2})');
          var match = regExp.firstMatch(fileName);
          if (match != null) {
            fileDate = DateTime(int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3)!), int.parse(match.group(4)!), int.parse(match.group(5)!));
            GlobalManager.addLog("從檔名成功解析真實錄音時間: $fileDate");
          } else fileDate = await file.lastModified();
        } catch (e) { GlobalManager.addLog("取得檔案時間失敗: $e"); }
        createNewNoteAndAnalyze([file.path], "匯入錄音", date: fileDate);
      }
    } else {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("需要存取檔案權限"), backgroundColor: Colors.red));
    }
  }

  Future<void> importYoutube() async {
    final TextEditingController urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("輸入 YouTube 連結"),
        content: TextField(controller: urlController, decoration: const InputDecoration(hintText: "[https://youtu.be/](https://youtu.be/)..."),),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          TextButton(onPressed: () => Navigator.pop(ctx, urlController.text), child: const Text("確定")),
        ],
      ),
    );

    if (url != null && url.isNotEmpty) {
      final noteId = const Uuid().v4();
      MeetingNote note = MeetingNote(id: noteId, title: "下載中...", date: DateTime.now(), summary: ["正在解析 YouTube 來源..."], audioPath: "", status: NoteStatus.downloading, currentStep: "正在解析影片來源...");
      await GlobalManager.saveNote(note);
      GlobalManager.addLog("🔄 YT狀態: ${note.currentStep}"); // 💡 修復 Log 遺失
      if (mounted) setState(() {});

      var yt = YoutubeExplode();
      try {
        var video = await yt.videos.get(url);
        note.title = "YT: ${video.title}"; 
        note.currentStep = "正在下載音訊串流...";
        await GlobalManager.saveNote(note);
        GlobalManager.addLog("🔄 YT狀態: ${note.currentStep}"); // 💡 修復 Log 遺失

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
            await fileStream.flush(); await fileStream.close();
            break;
          } catch (e) { audioFile = null; }
        }

        if (audioFile == null) {
          var muxedStreams = manifest.muxed.sortByBitrate().toList();
          for (var streamInfo in muxedStreams) {
            try {
              var stream = yt.videos.streamsClient.get(streamInfo);
              final dir = await getApplicationDocumentsDirectory();
              audioFile = File('${dir.path}/${video.id}.mp4');
              var fileStream = audioFile.openWrite();
              await stream.pipe(fileStream).timeout(const Duration(seconds: 20));
              await fileStream.flush(); await fileStream.close();
              break;
            } catch (e) { audioFile = null; }
          }
        }

        if (audioFile == null || !(await audioFile.exists())) throw Exception("下載失敗。");

        note.audioPath = audioFile.path; note.audioParts = [audioFile.path]; note.currentStep = '準備進行分析...';
        await GlobalManager.saveNote(note);
        GlobalManager.addLog("🔄 YT狀態: 下載完成，準備進行分析...");
        GlobalManager.analyzeNote(note);
      } catch (e) {
        GlobalManager.addLog("❌ YT處理最終失敗: $e");
        note.status = NoteStatus.failed; note.summary = ["下載失敗:\n$e"]; note.currentStep = '';
        await GlobalManager.saveNote(note);
        if (mounted) {
          // 💡 1.0.62 確保網頁能正確彈出並允許用戶自行設定備案網址
          final prefs = await SharedPreferences.getInstance();
          final String fallbackUrl = prefs.getString('yt_fallback_url') ?? "[https://yt5s.rip/en11/](https://yt5s.rip/en11/)";
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text("YouTube 解析失敗"),
              content: const Text("可能受到 YouTube 防爬蟲機制阻擋。\n是否為您開啟外部下載網頁？"),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
                FilledButton(
                  onPressed: () async { 
                    Navigator.pop(ctx); 
                    try {
                      await launchUrl(Uri.parse(fallbackUrl), mode: LaunchMode.externalApplication); 
                    } catch (e) {
                      GlobalManager.addLog("❌ 開啟網頁失敗: $e");
                    }
                  }, 
                  child: const Text("開啟下載網頁")
                ),
              ],
            ),
          );
        }
      } finally { yt.close(); }
    }
  }

  void showAddMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(leading: const Icon(Icons.mic, color: Colors.green), title: const Text('開始錄音'), onTap: () { Navigator.pop(context); toggleRecording(); }),
            ListTile(leading: const Icon(Icons.file_upload, color: Colors.blue), title: const Text('匯入本地錄音/音檔'), onTap: () { Navigator.pop(context); pickFile(); }),
            ListTile(leading: const Icon(Icons.ondemand_video, color: Colors.red), title: const Text('匯入 YouTube 影片'), onTap: () { Navigator.pop(context); importYoutube(); }),
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
          Expanded(child: IndexedStack(index: currentIndex, children: pages)),
          ValueListenableBuilder<bool>(
            valueListenable: GlobalManager.isRecordingNotifier,
            builder: (context, isRecording, child) {
              if (!isRecording) return const SizedBox.shrink();
              return Container(
                color: Colors.redAccent, padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Icon(Icons.mic, color: Colors.white),
                    Column(mainAxisSize: MainAxisSize.min, children: [Text("錄音中... $timerText", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), Text("Part $recordingPart", style: const TextStyle(color: Colors.white70, fontSize: 10))]),
                    IconButton(icon: const Icon(Icons.stop_circle, color: Colors.white), onPressed: toggleRecording),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(), notchMargin: 6.0,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(icon: Icon(Icons.home, color: currentIndex == 0 ? Colors.blue : Colors.grey), onPressed: () => setState(() => currentIndex = 0)),
              ValueListenableBuilder<bool>(
                valueListenable: GlobalManager.isRecordingNotifier,
                builder: (context, isRecording, child) {
                  return FloatingActionButton(onPressed: isRecording ? toggleRecording : showAddMenu, backgroundColor: isRecording ? Colors.red : Colors.blueAccent, child: Icon(isRecording ? Icons.stop : Icons.add, color: Colors.white));
                },
              ),
              IconButton(icon: Icon(Icons.settings, color: currentIndex == 1 ? Colors.blue : Colors.grey), onPressed: () => setState(() => currentIndex = 1)),
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
  void initState() { super.initState(); GlobalManager.loadNotes(); }

  Future<void> togglePin(MeetingNote note) async { note.isPinned = !note.isPinned; await GlobalManager.saveNote(note); }

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
                          background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
                          direction: DismissDirection.endToStart,
                          confirmDismiss: (direction) async {
                            if (note.isPinned) {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("📌 請先解除圖釘釘選，才能刪除此筆紀錄。")));
                              return false;
                            }
                            return await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text("確定要刪除嗎？"),
                                content: const Text("此操作將永久刪除該筆會議紀錄與實體錄音檔，無法復原。"),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text("取消")),
                                  TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text("刪除", style: TextStyle(color: Colors.red))),
                                ],
                              ),
                            );
                          },
                          onDismissed: (direction) => GlobalManager.deleteNote(note.id),
                          child: Card(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: note.status == NoteStatus.success ? Colors.green : (note.status == NoteStatus.failed ? Colors.red : Colors.orange),
                                child: Icon(note.status == NoteStatus.success ? Icons.check : (note.status == NoteStatus.failed ? Icons.error : Icons.hourglass_empty), color: Colors.white),
                              ),
                              title: Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(DateFormat('yyyy/MM/dd HH:mm').format(note.date)),
                                  if ((note.status == NoteStatus.processing || note.status == NoteStatus.downloading) && note.currentStep.isNotEmpty)
                                    Padding(padding: const EdgeInsets.only(top: 4.0), child: Text(note.currentStep, style: const TextStyle(color: Colors.blue, fontSize: 13, fontWeight: FontWeight.bold))),
                                  if (note.status == NoteStatus.failed)
                                    const Padding(padding: EdgeInsets.only(top: 4.0), child: Text("處理失敗，請查看日誌", style: TextStyle(color: Colors.red, fontSize: 13, fontWeight: FontWeight.bold))),
                                ],
                              ),
                              trailing: IconButton(icon: Icon(note.isPinned ? Icons.push_pin : Icons.push_pin_outlined, color: note.isPinned ? Colors.blue : Colors.grey), onPressed: () => togglePin(note)),
                              onTap: () async {
                                await Navigator.push(context, MaterialPageRoute(builder: (context) => NoteDetailPage(note: note)));
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

class _NoteDetailPageState extends State<NoteDetailPage> with SingleTickerProviderStateMixin {
  late MeetingNote _note;
  late TabController _tabController;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  final List<double> _partOffsets = [];
  int _currentPlayingPartIndex = 0;
  final ScrollController _transcriptScrollController = ScrollController();
  final Map<int, GlobalKey> _transcriptKeys = {};
  int _currentActiveTranscriptIndex = -1;
  final Set<String> _collapsedSections = {};
  bool _showOriginal = true; bool _showPhonetic = false; bool _showTranslation = true;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _tabController = TabController(length: 3, vsync: this);
    _initAudioOffsets();

    if (_note.status == NoteStatus.processing || _note.status == NoteStatus.downloading) {
      Timer.periodic(const Duration(seconds: 3), (timer) async {
        if (!mounted) { timer.cancel(); return; }
        await _reloadNote();
        if (_note.status == NoteStatus.success || _note.status == NoteStatus.failed) timer.cancel();
      });
    }

    _audioPlayer.onPlayerStateChanged.listen((state) { if (mounted) setState(() => _isPlaying = state == PlayerState.playing); });
    _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) {
        double offset = (_partOffsets.isNotEmpty && _currentPlayingPartIndex < _partOffsets.length) ? _partOffsets[_currentPlayingPartIndex] : 0;
        double globalSeconds = p.inMilliseconds / 1000.0 + offset;
        setState(() => _position = Duration(milliseconds: (globalSeconds * 1000).toInt()));

        if (_tabController.index == 1 && _note.transcript.isNotEmpty) {
          int newIndex = _note.transcript.lastIndexWhere((t) => globalSeconds >= t.startTime);
          if (newIndex != -1 && newIndex != _currentActiveTranscriptIndex) {
            setState(() {
              _currentActiveTranscriptIndex = newIndex;
              try {
                Section activeSec = _note.sections.lastWhere((s) => _note.transcript[newIndex].startTime >= s.startTime);
                if (_collapsedSections.contains(activeSec.title)) _collapsedSections.remove(activeSec.title);
              } catch (e) {}
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_transcriptKeys.containsKey(newIndex) && _transcriptKeys[newIndex]!.currentContext != null) {
                Scrollable.ensureVisible(_transcriptKeys[newIndex]!.currentContext!, duration: const Duration(milliseconds: 300), alignment: 0.3).catchError((_) {});
              }
            });
          }
        }
      }
    });

    _audioPlayer.onPlayerComplete.listen((_) async {
      List<String> paths = _note.audioParts.isNotEmpty ? _note.audioParts : [_note.audioPath];
      if (_currentPlayingPartIndex < paths.length - 1) {
        _currentPlayingPartIndex++;
        File actualFile = await GlobalManager.getActualFile(paths[_currentPlayingPartIndex]);
        if (await actualFile.exists()) await _audioPlayer.play(DeviceFileSource(actualFile.path));
      } else {
        if (mounted) setState(() { _isPlaying = false; _position = Duration.zero; _currentPlayingPartIndex = 0; });
      }
    });
  }

  Future<void> _initAudioOffsets() async {
    List<String> paths = _note.audioParts.isNotEmpty ? _note.audioParts : [_note.audioPath];
    double current = 0;
    for (String p in paths) {
      if (p.isEmpty) continue;
      _partOffsets.add(current);
      File f = await GlobalManager.getActualFile(p);
      if (await f.exists()) {
        final tempP = AudioPlayer(); await tempP.setSource(DeviceFileSource(f.path));
        final d = await tempP.getDuration(); current += (d?.inMilliseconds ?? 0) / 1000.0;
        await tempP.dispose();
      }
    }
    if (mounted) setState(() => _duration = Duration(milliseconds: (current * 1000).toInt()));
  }

  Future<void> _reloadNote() async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      final List<dynamic> jsonList = jsonDecode(existingJson);
      final updatedNoteJson = jsonList.firstWhere((e) => e['id'] == _note.id, orElse: () => null);
      if (updatedNoteJson != null) setState(() { _note = MeetingNote.fromJson(updatedNoteJson); });
    }
  }

  @override
  void dispose() { _tabController.dispose(); _transcriptScrollController.dispose(); _audioPlayer.dispose(); super.dispose(); }

  Future<void> _playPause() async {
    if (_isPlaying) await _audioPlayer.pause();
    else {
      List<String> paths = _note.audioParts.isNotEmpty ? _note.audioParts : [_note.audioPath];
      if (paths.isEmpty) return;
      File actualFile = await GlobalManager.getActualFile(paths[_currentPlayingPartIndex]);
      if (await actualFile.exists()) {
        if (_audioPlayer.source == null) await _audioPlayer.play(DeviceFileSource(actualFile.path));
        else await _audioPlayer.resume();
      } else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("找不到此音檔")));
    }
  }

  Future<void> _seekAndPlay(double seconds) async {
    await _seekTo(seconds);
    await Future.delayed(const Duration(milliseconds: 150));
    if (!_isPlaying) await _audioPlayer.resume();
  }

  Future<void> _seekTo(double seconds) async {
    List<String> paths = _note.audioParts.isNotEmpty ? _note.audioParts : [_note.audioPath];
    if (paths.isEmpty) return;
    if (paths.length <= 1) {
      File actualFile = await GlobalManager.getActualFile(paths.first);
      if (await actualFile.exists()) {
        if (_duration == Duration.zero && !_isPlaying) await _audioPlayer.setSource(DeviceFileSource(actualFile.path));
        await _audioPlayer.seek(Duration(seconds: seconds.toInt()));
      }
    } else {
      int targetPart = 0;
      for (int i = 0; i < _partOffsets.length; i++) { if (seconds >= _partOffsets[i]) targetPart = i; }
      double relativeSeconds = seconds - _partOffsets[targetPart];
      File actualFile = await GlobalManager.getActualFile(paths[targetPart]);
      if (await actualFile.exists()) {
        if (_currentPlayingPartIndex != targetPart || (!_isPlaying && _duration == Duration.zero)) {
          _currentPlayingPartIndex = targetPart;
          if (_isPlaying) await _audioPlayer.play(DeviceFileSource(actualFile.path));
          else await _audioPlayer.setSource(DeviceFileSource(actualFile.path));
        }
        await _audioPlayer.seek(Duration(seconds: relativeSeconds.toInt()));
      }
    }
  }

  Future<void> _saveNoteUpdate() async { await GlobalManager.saveNote(_note); }

  void _editTitle() {
    TextEditingController controller = TextEditingController(text: _note.title);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("修改標題"),
        content: TextField(controller: controller),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(onPressed: () { setState(() => _note.title = controller.text); _saveNoteUpdate(); Navigator.pop(context); }, child: const Text("儲存")),
        ],
      ),
    );
  }

  void _editSummaryItem(int index) {
    TextEditingController controller = TextEditingController(text: _note.summary[index]);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("編輯摘要"),
        content: TextField(controller: controller, maxLines: 3, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
          FilledButton(
            onPressed: () { setState(() => _note.summary[index] = controller.text); _saveNoteUpdate(); Navigator.pop(context); },
            child: const Text("儲存"),
          ),
        ],
      ),
    );
  }

  void _editTaskItem(int index) {
    TextEditingController descCtrl = TextEditingController(text: _note.tasks[index].description);
    TextEditingController assignCtrl = TextEditingController(text: _note.tasks[index].assignee);
    TextEditingController dueCtrl = TextEditingController(text: _note.tasks[index].dueDate);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("編輯任務"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: descCtrl, decoration: const InputDecoration(labelText: "任務內容")),
            TextField(controller: assignCtrl, decoration: const InputDecoration(labelText: "負責人")),
            TextField(controller: dueCtrl, decoration: const InputDecoration(labelText: "期限")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
          FilledButton(
            onPressed: () {
              setState(() {
                _note.tasks[index].description = descCtrl.text;
                _note.tasks[index].assignee = assignCtrl.text;
                _note.tasks[index].dueDate = dueCtrl.text;
              });
              _saveNoteUpdate(); Navigator.pop(context);
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
        content: const Text("請選擇您需要的重整層級：\n\n1. 【僅重整摘要與任務】：保留現有逐字稿，僅重新生成摘要。\n\n2. 【重新校正錯字與講者】：套用最新字典與名單，校正現有逐字稿並重整摘要 (極度省時省額度)。\n\n3. 【徹底語音重聽】：重新辨識音檔，覆蓋所有資料。"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(
            onPressed: () { GlobalManager.addLog("啟動重新分析: [僅重整摘要]"); Navigator.pop(context); setState(() { _note.status = NoteStatus.processing; _note.summary = ["AI 分析中 (僅重整摘要)..."]; }); GlobalManager.reSummarizeFromTranscript(_note).then((_) { if (mounted) _reloadNote(); }); },
            child: const Text("僅重整摘要"),
          ),
          TextButton(
            onPressed: () { GlobalManager.addLog("啟動重新分析: [校正錯字與講者]"); Navigator.pop(context); setState(() { _note.status = NoteStatus.processing; _note.summary = ["AI 正在校正錯字與講者..."]; }); GlobalManager.reCalibrateTranscript(_note).then((_) { if (mounted) _reloadNote(); }); },
            child: const Text("校正錯字與講者", style: TextStyle(color: Colors.green)),
          ),
          TextButton(
            onPressed: () { GlobalManager.addLog("啟動重新分析: [徹底語音重聽]"); Navigator.pop(context); setState(() { _note.status = NoteStatus.processing; _note.summary = ["AI 徹底語音重聽分析中..."]; }); GlobalManager.analyzeNote(_note).then((_) { if (mounted) _reloadNote(); }); },
            child: const Text("徹底語音重聽", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showTranslateDialog() {
    String selectedLang = 'en';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateSB) => AlertDialog(
          title: const Text("翻譯逐字稿"),
          content: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("請選擇目標語言，AI 將為您產生對應的翻譯與拼音。"), const SizedBox(height: 16),
              DropdownButton<String>(
                isExpanded: true, value: selectedLang,
                items: const [
                  DropdownMenuItem(value: 'en', child: Text("英文 (English)")),
                  DropdownMenuItem(value: 'ja', child: Text("日文 (日本語 + Romaji)")),
                  DropdownMenuItem(value: 'ko', child: Text("韓文 (한국어 + Romaja)")),
                  DropdownMenuItem(value: 'zh', child: Text("繁體中文 (+ 漢語拼音)")),
                ],
                onChanged: (val) { setStateSB(() => selectedLang = val!); },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
            FilledButton(onPressed: () { Navigator.pop(ctx); setState(() { _note.status = NoteStatus.processing; _note.summary = ["AI 正在翻譯逐字稿..."]; }); GlobalManager.translateTranscript(_note, selectedLang).then((_) { if (mounted) _reloadNote(); }); }, child: const Text("開始翻譯")),
          ],
        ),
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
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("選擇既有與會者:", style: TextStyle(fontWeight: FontWeight.bold)),
              ValueListenableBuilder<List<String>>(
                valueListenable: GlobalManager.participantListNotifier,
                builder: (context, participants, child) { return Wrap(spacing: 8, children: participants.map((name) { return ActionChip(label: Text(name), onPressed: () => _confirmSpeakerChange(index, currentSpeaker, name)); }).toList()); },
              ),
              const Divider(height: 20),
              const Text("或輸入新名稱:", style: TextStyle(fontWeight: FontWeight.bold)),
              TextField(controller: customController, decoration: const InputDecoration(labelText: "新名稱")),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
          FilledButton(onPressed: () { if (customController.text.isNotEmpty) { GlobalManager.addParticipant(customController.text); _confirmSpeakerChange(index, currentSpeaker, customController.text); } }, child: const Text("確定")),
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
          TextButton(onPressed: () { setState(() { _note.transcript[index].speaker = newName; }); _saveNoteUpdate(); Navigator.pop(context); }, child: const Text("僅此句")),
          FilledButton(onPressed: () { setState(() { for (var item in _note.transcript) { if (item.speaker == oldName) item.speaker = newName; } }); _saveNoteUpdate(); Navigator.pop(context); }, child: const Text("全部修改")),
        ],
      ),
    );
  }

  void _editTranscriptItem(int index) {
    TextEditingController controller = TextEditingController(text: _note.transcript[index].original);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("編輯逐字稿"),
        content: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: controller, maxLines: 5, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "修改內容...")),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: Text("💡 提示：在上方框選文字後可加入字典，或點擊游標位置使用斷句功能。", style: TextStyle(fontSize: 10, color: Colors.grey))),
                IconButton(
                  icon: const Icon(Icons.call_split, color: Colors.blue), tooltip: "從游標處斷開為兩句",
                  onPressed: () {
                    int pos = controller.selection.baseOffset;
                    if (pos > 0 && pos < controller.text.length) {
                      String part1 = controller.text.substring(0, pos).trim(); String part2 = controller.text.substring(pos).trim();
                      double currentStartTime = _note.transcript[index].startTime;
                      double estimatedDuration = controller.text.length * 0.3;
                      double nextStartTime = currentStartTime + estimatedDuration;
                      if (index + 1 < _note.transcript.length) { double actualNextTime = _note.transcript[index + 1].startTime; if (actualNextTime < nextStartTime) nextStartTime = actualNextTime; }
                      double ratio = pos / controller.text.length;
                      double newStartTime = currentStartTime + ((nextStartTime - currentStartTime) * ratio);
                      setState(() { _note.transcript[index].original = part1; _note.transcript.insert(index + 1, TranscriptItem(speaker: _note.transcript[index].speaker, original: part2, startTime: double.parse(newStartTime.toStringAsFixed(1)))); });
                      _saveNoteUpdate(); Navigator.pop(dialogContext); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已斷開並自動推算精準新時間！")));
                    } else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("請先點擊文字內容，指定要斷句的游標位置")));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.bookmark_add, color: Colors.orange), tooltip: "將框選文字加入字典",
                  onPressed: () {
                    if (controller.selection.isValid && !controller.selection.isCollapsed) {
                      String selectedText = controller.selection.textInside(controller.text);
                      GlobalManager.addVocab(selectedText); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已將「$selectedText」加入字典")));
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.spellcheck, color: Colors.purple), tooltip: "將框選文字加入錯字記憶庫",
                  onPressed: () {
                    String selectedText = "";
                    if (controller.selection.isValid && !controller.selection.isCollapsed) selectedText = controller.selection.textInside(controller.text);
                    TextEditingController wrongCtrl = TextEditingController(text: selectedText);
                    TextEditingController correctCtrl = TextEditingController();
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text("新增錯字記憶"),
                        content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: wrongCtrl, decoration: const InputDecoration(labelText: "AI 常聽錯的字 (如: 頻狗)")), const SizedBox(height: 8), TextField(controller: correctCtrl, decoration: const InputDecoration(labelText: "要替換的正確字 (如: 蘋果)"), autofocus: true)]),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
                          FilledButton(onPressed: () {
                            final w = wrongCtrl.text.trim(); final c = correctCtrl.text.trim();
                            if (w.isNotEmpty && c.isNotEmpty) {
                              final list = List<String>.from(GlobalManager.typoListNotifier.value); list.add("$w ➡️ $c"); GlobalManager.saveTypoList(list);
                              setState(() { controller.text = controller.text.replaceAll(w, c); });
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已加入記憶庫並自動替換：$w ➡️ $c"))); Navigator.pop(ctx);
                            }
                          }, child: const Text("儲存")),
                        ],
                      ),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.language, color: Colors.blue), tooltip: "局部外語重聽 (解決漏字或外語辨識錯誤)",
                  onPressed: () {
                    FocusScope.of(context).unfocus();
                    String selectedLang = 'ja';
                    showDialog(
                      context: context,
                      builder: (ctx) => StatefulBuilder(
                        builder: (context, setStateSB) => AlertDialog(
                          title: const Text("🎧 局部語言重聽"),
                          content: Column(
                            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("若此段落有漏字或外語辨識錯誤，可指定語系重新聽寫此段落 (往後涵蓋約 45 秒)。", style: TextStyle(fontSize: 13)),
                              const SizedBox(height: 16),
                              DropdownButton<String>(
                                isExpanded: true, value: selectedLang,
                                items: const [
                                  DropdownMenuItem(value: 'en', child: Text("英文 (English)")),
                                  DropdownMenuItem(value: 'ja', child: Text("日文 (日本語)")),
                                  DropdownMenuItem(value: 'ko', child: Text("韓文 (한국어)")),
                                  DropdownMenuItem(value: 'zh', child: Text("繁體中文 (zh-TW)")),
                                  DropdownMenuItem(value: 'auto', child: Text("自動偵測 (Auto)")),
                                ],
                                onChanged: (val) { setStateSB(() => selectedLang = val!); },
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
                            FilledButton(
                              onPressed: () {
                                Navigator.pop(ctx); Navigator.pop(dialogContext);
                                GlobalManager.reListenSegment(_note, index, selectedLang).then((_) { if (mounted) _reloadNote(); });
                              },
                              child: const Text("開始重聽"),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("取消")),
          FilledButton(onPressed: () { setState(() { _note.transcript[index].original = controller.text; }); _saveNoteUpdate(); Navigator.pop(dialogContext); }, child: const Text("儲存修改")),
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
      if (ext == 'csv' || ext == 'md') bytes.addAll([0xEF, 0xBB, 0xBF]);
      bytes.addAll(utf8.encode(content));
      await file.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(file.path)], text: '會議記錄匯出: ${_note.title}');
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("匯出失敗: $e"))); }
  }

  Future<void> _exportCsv() async {
    StringBuffer csv = StringBuffer();
    csv.writeln("會議標題,${_note.title.replaceAll('"', '""')}");
    csv.writeln("會議日期,${DateFormat('yyyy/MM/dd HH:mm').format(_note.date)}\n");
    csv.writeln("【重點摘要】");
    for (var s in _note.summary) { csv.writeln('"${s.replaceAll('"', '""')}"'); }
    csv.writeln("\n【待辦事項】\n任務,負責人,期限");
    for (var t in _note.tasks) { csv.writeln('"${t.description.replaceAll('"', '""')}","${t.assignee}","${t.dueDate}"'); }
    csv.writeln("\n【逐字稿】\n時間,說話者,原文內容,翻譯內容");
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
    for (var s in _note.summary) { md.writeln("- $s"); }
    md.writeln("\n## ✅ 待辦事項\n| 任務 | 負責人 | 期限 |\n|---|---|---|");
    for (var t in _note.tasks) { md.writeln("| ${t.description} | ${t.assignee} | ${t.dueDate} |"); }
    md.writeln("\n## 💬 逐字稿");
    for (var item in _note.transcript) {
      String time = GlobalManager.formatTime(item.startTime);
      String transSuffix = item.translation.isNotEmpty && item.translation != item.original ? ' (${item.translation})' : '';
      md.writeln("**$time [${item.speaker}]**: ${item.original}$transSuffix\n");
    }
    await _exportFile('md', md.toString());
  }

  Future<void> _exportRawSTT() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String strategy = prefs.getString('analysis_strategy') ?? 'deepgram_gemini';
      final String engineName = strategy.contains('deepgram') ? 'Deepgram' : 'Gemini/Groq';
      
      final dir = await getApplicationDocumentsDirectory();
      final internalFile = File('${dir.path}/${_note.id}_raw_stt.txt');
      String content = "";
      
      if (await internalFile.exists()) {
        content = await internalFile.readAsString();
      } else {
        StringBuffer raw = StringBuffer();
        for (var item in _note.transcript) { raw.writeln("[${item.startTime}s] ${item.speaker}: ${item.original}"); }
        content = raw.toString();
      }

      final safeTitle = _note.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final exportFile = File('${dir.path}/${safeTitle}_raw_stt.txt');
      await exportFile.writeAsString("【$engineName STT 原始聽寫稿 (除錯用)】\n會議標題: ${_note.title}\n\n$content");
      await Share.shareXFiles([XFile(exportFile.path)], text: '匯出原始 STT 聽寫稿');
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("匯出失敗: $e"))); }
  }

  Future<void> _generatePdf() async {
    final pdf = pw.Document();
    final fontRegular = await PdfGoogleFonts.notoSansTCRegular();
    final fontBold = await PdfGoogleFonts.notoSansTCBold();
    final fontKorean = await PdfGoogleFonts.notoSansKRRegular();

    pdf.addPage(pw.MultiPage(
      theme: pw.ThemeData.withFont(base: fontRegular, bold: fontBold, fontFallback: [fontKorean]),
      build: (context) => [
        pw.Header(level: 0, child: pw.Text(_note.title, style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold))),
        pw.Text("日期: ${DateFormat('yyyy/MM/dd HH:mm').format(_note.date)}"), pw.Divider(),
        pw.Header(level: 1, child: pw.Text("重點摘要")),
        ..._note.summary.map((s) => pw.Bullet(text: s)), pw.SizedBox(height: 10),
        pw.Header(level: 1, child: pw.Text("待辦事項")),
        pw.Table.fromTextArray(headers: ["任務", "負責人", "期限"], data: _note.tasks.map((t) => [t.description, t.assignee, t.dueDate]).toList()), pw.SizedBox(height: 10),
        pw.Header(level: 1, child: pw.Text("逐字稿")),
        ..._note.transcript.map((t) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.SizedBox(width: 40, child: pw.Text(GlobalManager.formatTime(t.startTime), style: const pw.TextStyle(color: PdfColors.grey))),
            pw.SizedBox(width: 60, child: pw.Text(t.speaker, style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
            pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(t.original),
              if (t.translation.isNotEmpty && t.translation != t.original) pw.Text(t.translation, style: const pw.TextStyle(color: PdfColors.blueGrey)),
            ])),
          ]),
        )),
      ],
    ));
    await Printing.sharePdf(bytes: await pdf.save(), filename: 'meeting_note.pdf');
  }

  Future<void> _exportAudio() async {
    try {
      List<String> paths = _note.audioParts.isNotEmpty ? _note.audioParts : [_note.audioPath];
      List<XFile> shareFiles = [];
      for (var p in paths) {
        if (p.isEmpty) continue;
        File f = await GlobalManager.getActualFile(p);
        if (await f.exists()) shareFiles.add(XFile(f.path));
      }
      if (shareFiles.isNotEmpty) await Share.shareXFiles(shareFiles, text: '匯出會議音檔: ${_note.title}');
      else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("找不到實體音檔")));
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("音檔匯出失敗: $e"))); }
  }

  Future<void> _confirmDelete() async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("確定要刪除嗎？"),
        content: const Text("此操作無法復原。"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("刪除", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) { await GlobalManager.deleteNote(_note.id); if (mounted) Navigator.pop(context); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(onTap: _editTitle, child: Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: Text(_note.title, overflow: TextOverflow.ellipsis)), const SizedBox(width: 4), const Icon(Icons.edit, size: 16, color: Colors.white54)])),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: "重新分析", onPressed: _reAnalyze),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'translate') _showTranslateDialog();
              if (value == 'pdf') _generatePdf(); if (value == 'csv') _exportCsv(); if (value == 'md') _exportMarkdown();
              if (value == 'raw_stt') _exportRawSTT(); if (value == 'audio') _exportAudio(); if (value == 'delete') _confirmDelete();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'translate', child: Text("🌐 翻譯逐字稿", style: TextStyle(color: Colors.teal))),
              const PopupMenuItem(value: 'pdf', child: Text("匯出 PDF")),
              const PopupMenuItem(value: 'csv', child: Text("匯出 Excel (CSV)")),
              const PopupMenuItem(value: 'md', child: Text("匯出 Markdown")),
              const PopupMenuItem(value: 'raw_stt', child: Text("匯出 STT 原始稿 (除錯)", style: TextStyle(color: Colors.deepPurple))),
              const PopupMenuItem(value: 'audio', child: Text("匯出原始音檔", style: TextStyle(color: Colors.blue))),
              const PopupMenuItem(value: 'delete', child: Text("刪除紀錄", style: TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12), color: Colors.grey[200],
            child: Row(
              children: [
                IconButton(icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 40, color: Colors.blue), onPressed: _playPause),
                Expanded(child: Slider(value: _position.inSeconds.toDouble(), max: _duration.inSeconds.toDouble() > 0 ? _duration.inSeconds.toDouble() : 1.0, onChanged: (v) => _seekTo(v))),
                Text("${GlobalManager.formatTime(_position.inSeconds.toDouble())} / ${GlobalManager.formatTime(_duration.inSeconds.toDouble())}"),
              ],
            ),
          ),
          TabBar(controller: _tabController, labelColor: Colors.blue, unselectedLabelColor: Colors.grey, tabs: const [Tab(text: "摘要 & 任務"), Tab(text: "逐字稿"), Tab(text: "段落回顧")]),
          Expanded(
            child: _note.status == NoteStatus.processing || _note.status == NoteStatus.downloading
                ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const CircularProgressIndicator(), const SizedBox(height: 16), Text(_note.currentStep.isNotEmpty ? _note.currentStep : "AI 分析中...")]))
                : _note.status == NoteStatus.failed
                    ? Center(child: Padding(padding: const EdgeInsets.all(16.0), child: Text("分析失敗: ${_note.summary.firstOrNull}", textAlign: TextAlign.center, style: const TextStyle(color: Colors.red))))
                    : TabBarView(controller: _tabController, children: [_buildSummaryTab(), _buildTranscriptTab(), _buildSectionTab()]),
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
          const Text("📝 重點摘要 (長按可編輯)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ..._note.summary.asMap().entries.map(
            (entry) => InkWell(
              onLongPress: () => _editSummaryItem(entry.key),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("• ", style: TextStyle(fontSize: 16)),
                    Expanded(child: Text(entry.value, style: const TextStyle(fontSize: 16))),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 32),
          const Text("✅ 待辦事項 (長按可編輯)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ..._note.tasks.asMap().entries.map(
            (entry) => InkWell(
              onLongPress: () => _editTaskItem(entry.key),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.check_box_outline_blank),
                  title: Text(entry.value.description),
                  subtitle: Text("負責人: ${entry.value.assignee}  期限: ${entry.value.dueDate}"),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParsedText(TranscriptItem item) {
    List<Widget> widgets = [];
    if (_showOriginal && item.original.isNotEmpty) widgets.add(Text(item.original, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)));
    if (_showPhonetic && item.phonetic.isNotEmpty) widgets.add(Text(item.phonetic, style: const TextStyle(fontSize: 14, color: Colors.blueGrey, fontStyle: FontStyle.italic)));
    if (_showTranslation && item.translation.isNotEmpty && item.translation != item.original) widgets.add(Text(item.translation, style: TextStyle(fontSize: 16, color: Colors.green.shade700)));
    if (widgets.isEmpty) return const Text("...", style: TextStyle(color: Colors.grey));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets);
  }

  Widget _buildTranscriptTab() {
    List<Widget> listItems = [];
    if (_note.transcript.isNotEmpty) {
      listItems.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), color: Colors.grey.shade50,
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center, spacing: 8,
            children: [
              const Icon(Icons.g_translate, size: 18, color: Colors.blueGrey),
              const Text("多語系：", style: TextStyle(fontSize: 12, color: Colors.blueGrey, fontWeight: FontWeight.bold)),
              FilterChip(label: const Text("原文", style: TextStyle(fontSize: 12)), selected: _showOriginal, onSelected: (val) => setState(() => _showOriginal = val), visualDensity: VisualDensity.compact, selectedColor: Colors.blue.shade100),
              FilterChip(label: const Text("拼音", style: TextStyle(fontSize: 12)), selected: _showPhonetic, onSelected: (val) => setState(() => _showPhonetic = val), visualDensity: VisualDensity.compact, selectedColor: Colors.blue.shade100),
              FilterChip(label: const Text("翻譯", style: TextStyle(fontSize: 12)), selected: _showTranslation, onSelected: (val) => setState(() => _showTranslation = val), visualDensity: VisualDensity.compact, selectedColor: Colors.blue.shade100),
            ],
          ),
        ),
      );
    }

    String? currentChapter;
    String getSpeakerAvatarChar(String name) {
      if (name.isEmpty) return "?"; String cleanName = name.trim();
      if (cleanName.toLowerCase().startsWith('speaker ')) return cleanName.split(' ').last[0].toUpperCase();
      if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(cleanName) && cleanName.length >= 2) return cleanName.substring(cleanName.length - 1);
      if (cleanName.contains(' ')) return cleanName.split(' ').last[0].toUpperCase();
      return cleanName[0].toUpperCase();
    }

    for (int i = 0; i < _note.transcript.length; i++) {
      final item = _note.transcript[i];
      Section? sec;
      try { sec = _note.sections.lastWhere((s) => item.startTime >= s.startTime); } catch (e) { sec = null; }

      if (sec != null && sec.title != currentChapter) {
        currentChapter = sec.title; bool isCollapsed = _collapsedSections.contains(currentChapter);
        listItems.add(
          InkWell(
            onTap: () { setState(() { if (_collapsedSections.contains(sec!.title)) _collapsedSections.remove(sec.title); else _collapsedSections.add(sec.title); }); },
            child: Container(
              width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16), color: Colors.blue.shade100,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("🔖 $currentChapter", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
                  Icon(isCollapsed ? Icons.expand_more : Icons.expand_less, color: Colors.blue.shade900),
                ],
              ),
            ),
          ),
        );
      }

      if (sec != null && _collapsedSections.contains(sec.title)) continue;

      if (!_transcriptKeys.containsKey(i)) _transcriptKeys[i] = GlobalKey();
      bool isActive = i == _currentActiveTranscriptIndex;

      listItems.add(
        Material(
          key: _transcriptKeys[i],
          color: isActive ? Colors.yellow.withOpacity(0.3) : Colors.transparent,
          child: InkWell(
            onTap: () => _seekTo(item.startTime), onDoubleTap: () => _seekAndPlay(item.startTime), onLongPress: () => _editTranscriptItem(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(onTap: () => _changeSpeaker(i), child: CircleAvatar(child: Text(getSpeakerAvatarChar(item.speaker)))),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.speaker, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey)),
                        const SizedBox(height: 4),
                        _buildParsedText(item),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(GlobalManager.formatTime(item.startTime), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return SingleChildScrollView(controller: _transcriptScrollController, child: Column(children: listItems));
  }

  Widget _buildSectionTab() {
    return ListView.builder(
      itemCount: _note.sections.length,
      itemBuilder: (context, index) {
        final section = _note.sections[index];
        return Card(
          margin: const EdgeInsets.all(8),
          child: ListTile(
            title: Text(section.title, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text("${GlobalManager.formatTime(section.startTime)} - ${GlobalManager.formatTime(section.endTime)}"),
            leading: const Icon(Icons.bookmark),
            onTap: () {
              setState(() { _collapsedSections.remove(section.title); });
              _tabController.animateTo(1);
              int targetIndex = _note.transcript.indexWhere((t) => t.startTime >= section.startTime);
              if (targetIndex != -1) {
                setState(() => _currentActiveTranscriptIndex = targetIndex);
                void tryScroll(int retries) {
                  if (!mounted) return;
                  final ctx = _transcriptKeys[targetIndex]?.currentContext;
                  if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.1).catchError((_) {});
                  else if (retries > 0) Future.delayed(const Duration(milliseconds: 100), () => tryScroll(retries - 1));
                }
                Future.delayed(const Duration(milliseconds: 100), () => tryScroll(10));
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
  final TextEditingController _deepgramKeyController = TextEditingController(); 
  
  // 💡 1.0.62 新增：各項進階參數的 Controller 與變數
  final TextEditingController _ytFallbackUrlController = TextEditingController();
  final TextEditingController _dgUttSplitController = TextEditingController();
  final TextEditingController _groqTempController = TextEditingController();
  bool _dgSmartFormat = false;
  bool _dgFillerWords = true;

  String _analysisStrategy = 'flash';
  String _sttLanguage = 'zh';
  bool _isLoadingModels = false;
  bool _isLoadingExternalSTT = false;

  @override
  void initState() { super.initState(); _loadSettings(); }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text = prefs.getString('api_key') ?? '';
      _groqKeyController.text = prefs.getString('groq_api_key') ?? '';
      _deepgramKeyController.text = prefs.getString('deepgram_api_key') ?? '';
      _analysisStrategy = prefs.getString('analysis_strategy') ?? 'flash';
      _sttLanguage = prefs.getString('stt_language') ?? 'zh';
      
      _ytFallbackUrlController.text = prefs.getString('yt_fallback_url') ?? "[https://yt5s.rip/en11/](https://yt5s.rip/en11/)";
      _dgUttSplitController.text = (prefs.getDouble('dg_utt_split') ?? 1.5).toString();
      _groqTempController.text = (prefs.getDouble('groq_temperature') ?? 0.0).toString();
      _dgSmartFormat = prefs.getBool('dg_smart_format') ?? false;
      _dgFillerWords = prefs.getBool('dg_filler_words') ?? true;
    });
  }

  void _showApiKeyGuide(String type) {
    String title = ""; String url = ""; String steps = "";
    if (type == 'gemini') { title = "取得 Gemini API Key"; url = "[https://aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey)"; steps = "1. 點擊下方按鈕前往 Google AI Studio\n2. 登入 Google 帳號\n3. 點擊畫面上的「Create API key」\n4. 複製金鑰並貼上至此處"; }
    else if (type == 'deepgram') { title = "取得 Deepgram API Key"; url = "[https://console.deepgram.com/](https://console.deepgram.com/)"; steps = "1. 點擊下方按鈕前往 Deepgram\n2. 註冊並登入帳號 (註冊即贈 \$200 額度)\n3. 在左側選單進入「API Keys」\n4. 點擊「Create a New API Key」\n5. 複製金鑰並貼上至此處"; }
    else if (type == 'groq') { title = "取得 Groq API Key"; url = "[https://console.groq.com/keys](https://console.groq.com/keys)"; steps = "1. 點擊下方按鈕前往 Groq Cloud\n2. 登入帳號\n3. 點擊「Create API Key」\n4. 複製金鑰並貼上至此處"; }
    showDialog(context: context, builder: (ctx) => AlertDialog(title: Text(title), content: Text(steps), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")), FilledButton(onPressed: () { Navigator.pop(ctx); launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication); }, child: const Text("前往申請"))]));
  }

  Future<void> _testApiConnection() async {
    final rawKeys = _apiKeyController.text.trim();
    if (rawKeys.isEmpty) { _showApiKeyGuide('gemini'); return; }
    setState(() => _isLoadingModels = true);
    final firstKey = rawKeys.split(',').map((e) => e.trim()).firstWhere((e) => e.isNotEmpty, orElse: () => '');
    try { await GeminiRestApi.getAvailableModels(firstKey); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ Gemini API 測試成功！網路連線正常"), backgroundColor: Colors.green)); _saveSettings(); }
    catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("❌ Gemini 測試失敗: $e"), backgroundColor: Colors.red)); }
    finally { if (mounted) setState(() => _isLoadingModels = false); }
  }

  Future<void> _testExternalSTT() async {
    if (_analysisStrategy == 'groq_gemini' && _groqKeyController.text.isEmpty) { _showApiKeyGuide('groq'); return; }
    if (_analysisStrategy == 'deepgram_gemini' && _deepgramKeyController.text.isEmpty) { _showApiKeyGuide('deepgram'); return; }
    setState(() => _isLoadingExternalSTT = true);
    try {
      if (_analysisStrategy == 'groq_gemini') { await GroqApi.testApiKey(_groqKeyController.text.trim()); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ Groq API 測試成功！"), backgroundColor: Colors.green)); }
      else if (_analysisStrategy == 'deepgram_gemini') { await DeepgramApi.testApiKey(_deepgramKeyController.text.trim()); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ Deepgram API 測試成功！"), backgroundColor: Colors.green)); }
      else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("請先在下方選擇雙引擎模式"), backgroundColor: Colors.orange)); }
      _saveSettings();
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("❌ 測試失敗: $e"), backgroundColor: Colors.red)); }
    finally { if (mounted) setState(() => _isLoadingExternalSTT = false); }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text);
    await prefs.setString('groq_api_key', _groqKeyController.text);
    await prefs.setString('deepgram_api_key', _deepgramKeyController.text);
    await prefs.setString('analysis_strategy', _analysisStrategy);
    await prefs.setString('stt_language', _sttLanguage);
    
    // 💡 1.0.62 儲存進階參數
    await prefs.setString('yt_fallback_url', _ytFallbackUrlController.text);
    await prefs.setDouble('dg_utt_split', double.tryParse(_dgUttSplitController.text) ?? 1.5);
    await prefs.setDouble('groq_temperature', double.tryParse(_groqTempController.text) ?? 0.0);
    await prefs.setBool('dg_smart_format', _dgSmartFormat);
    await prefs.setBool('dg_filler_words', _dgFillerWords);
    
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("設定已儲存")));
  }

  @override
  Widget build(BuildContext context) {
    int daysSinceFirstUse = UsageTracker.firstUseDate == null ? 1 : DateTime.now().difference(UsageTracker.firstUseDate!).inDays;
    if (daysSinceFirstUse < 1) daysSinceFirstUse = 1;
    double groqCost = (UsageTracker.groqAudioSeconds / 3600) * 0.10;
    double deepgramCost = (UsageTracker.deepgramAudioSeconds / 60) * 0.0043;
    double geminiTextCost = UsageTracker.geminiTextRequests * 0.0001125;
    double geminiAudioCost = (UsageTracker.geminiAudioSeconds / 60) * 0.0012;
    double totalCurrentCost = groqCost + deepgramCost + geminiTextCost + geminiAudioCost;
    double projectedMonthlyCost = (totalCurrentCost / daysSinceFirstUse) * 30;

    return Scaffold(
      appBar: AppBar(
        title: const Text("設定"),
        actions: [IconButton(icon: const Icon(Icons.bug_report, color: Colors.red), onPressed: () { Navigator.push(context, MaterialPageRoute(builder: (context) => const LogViewerPage())); })],
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(), // 點擊空白處收起鍵盤
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text("API 設定 (安全遮蔽)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 8),
            Focus(onFocusChange: (focus) { if(!focus) _saveSettings(); }, child: TextField(controller: _apiKeyController, maxLines: 1, obscureText: true, decoration: const InputDecoration(labelText: "Gemini API Keys", hintText: "可輸入多把 Key，請用半形逗號 , 分隔", border: OutlineInputBorder()))), const SizedBox(height: 10),
            Focus(onFocusChange: (focus) { if(!focus) _saveSettings(); }, child: TextField(controller: _deepgramKeyController, maxLines: 1, obscureText: true, decoration: const InputDecoration(labelText: "Deepgram API Key (備用 STT)", hintText: "至 console.deepgram.com 免費申請", border: OutlineInputBorder(), suffixIcon: Icon(Icons.mic)))), const SizedBox(height: 10),
            Focus(onFocusChange: (focus) { if(!focus) _saveSettings(); }, child: TextField(controller: _groqKeyController, maxLines: 1, obscureText: true, decoration: const InputDecoration(labelText: "Groq API Key (備用 STT)", hintText: "至 [https://console.groq.com/keys](https://console.groq.com/keys) 免費申請", border: OutlineInputBorder(), suffixIcon: Icon(Icons.mic_external_off)))), const SizedBox(height: 10),
            Row(children: [Expanded(child: ElevatedButton.icon(onPressed: _isLoadingModels ? null : _testApiConnection, icon: _isLoadingModels ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_done), label: Text(_isLoadingModels ? "測試中..." : "測試 Gemini"))), const SizedBox(width: 10), Expanded(child: ElevatedButton.icon(onPressed: _isLoadingExternalSTT ? null : _testExternalSTT, icon: _isLoadingExternalSTT ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.settings_voice), label: Text(_isLoadingExternalSTT ? "測試中..." : "測試 STT 引擎"), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade50, foregroundColor: Colors.orange.shade800)))]), const SizedBox(height: 20),
            
            const Text("分析模式 (AI 核心策略)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 8),
            Container(padding: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade400), borderRadius: BorderRadius.circular(8)), child: DropdownButtonHideUnderline(child: DropdownButton<String>(
              value: _analysisStrategy, isExpanded: true, 
              items: const [
                DropdownMenuItem(value: 'flash', child: Text("🏆 首選：原生語音模式 (純 Gemini Flash)")), 
                DropdownMenuItem(value: 'deepgram_gemini', child: Text("🥈 備案：雙引擎模式 (Deepgram + Gemini)")), 
                DropdownMenuItem(value: 'groq_gemini', child: Text("🥉 備案：雙引擎模式 (Groq + Gemini)")), 
                DropdownMenuItem(value: 'pro', child: Text("精準高密模式 (純 Gemini Pro)"))
              ], onChanged: (val) { setState(() => _analysisStrategy = val!); _saveSettings(); }))), const SizedBox(height: 4),
            const Text("💡 提示：Gemini Flash 原生模式能直接聆聽語氣並理解多國語言夾雜，為複雜會議的最佳選擇。", style: TextStyle(fontSize: 12, color: Colors.green)), const SizedBox(height: 20),
            
            const Text("主要錄音語系 (STT 引擎提示)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 8),
            Container(padding: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade400), borderRadius: BorderRadius.circular(8)), child: DropdownButtonHideUnderline(child: DropdownButton<String>(value: _sttLanguage, isExpanded: true, items: const [DropdownMenuItem(value: 'zh', child: Text("繁體中文 (zh-TW)")), DropdownMenuItem(value: 'en', child: Text("英文 (English)")), DropdownMenuItem(value: 'ja', child: Text("日文 (日本語)")), DropdownMenuItem(value: 'ko', child: Text("韓文 (한국어)")), DropdownMenuItem(value: 'auto', child: Text("自動偵測 (Auto)"))], onChanged: (val) { setState(() => _sttLanguage = val!); _saveSettings(); }))), const SizedBox(height: 20),
            
            // 💡 1.0.62 新增：進階參數設定摺疊區塊
            ExpansionTile(
              title: const Text("⚙️ 進階 STT 引擎與系統參數設定", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
              childrenPadding: const EdgeInsets.all(8),
              children: [
                const Text("此區參數為 Deepgram 與 Groq 聽寫時的微調控制，修改後會在下一次分析生效。", style: TextStyle(fontSize: 12, color: Colors.grey)),
                const Divider(),
                SwitchListTile(
                  title: const Text("Deepgram: 智能排版 (Smart Format)"),
                  subtitle: const Text("對中文支援極差，開啟可能導致中文完全被過濾！強烈建議保持關閉。"),
                  value: _dgSmartFormat,
                  onChanged: (val) { setState(() => _dgSmartFormat = val); _saveSettings(); },
                ),
                SwitchListTile(
                  title: const Text("Deepgram: 保留發語詞 (Filler Words)"),
                  subtitle: const Text("預設開啟。保留「呃、那個」等聲音以確保時間軸連貫。"),
                  value: _dgFillerWords,
                  onChanged: (val) { setState(() => _dgFillerWords = val); _saveSettings(); },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                  child: Focus(
                    onFocusChange: (focus) { if(!focus) _saveSettings(); },
                    child: TextField(
                      controller: _dgUttSplitController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: "Deepgram 斷句等待時間 (秒)", hintText: "預設 1.5", border: OutlineInputBorder(), helperText: "數值越大，一句話會越長，能避免過度碎裂的短句。"),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                  child: Focus(
                    onFocusChange: (focus) { if(!focus) _saveSettings(); },
                    child: TextField(
                      controller: _groqTempController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: "Groq 創意溫度值 (Temperature)", hintText: "預設 0.0", border: OutlineInputBorder(), helperText: "0.0 最為精準；調高 (如 0.5) 會增加模型猜測能力但也可能產生幻覺。"),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                  child: Focus(
                    onFocusChange: (focus) { if(!focus) _saveSettings(); },
                    child: TextField(
                      controller: _ytFallbackUrlController,
                      decoration: const InputDecoration(labelText: "YT 備案下載網址", hintText: "[https://yt5s.rip/en11/](https://yt5s.rip/en11/)", border: OutlineInputBorder(), helperText: "當程式無法自動下載 YouTube 時，引導跳轉至瀏覽器的網址。"),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            Card(color: Colors.blue.shade50, child: Padding(padding: const EdgeInsets.all(16.0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Row(children: [Icon(Icons.monetization_on, color: Colors.blue), SizedBox(width: 8), Text("動態成本估算器", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))]), Text("第 $daysSinceFirstUse 天", style: const TextStyle(fontSize: 12, color: Colors.grey))]), const SizedBox(height: 12), Text("🎙️ Deepgram STT 音訊: ${(UsageTracker.deepgramAudioSeconds / 3600).toStringAsFixed(2)} 小時 (\$${deepgramCost.toStringAsFixed(3)})", style: const TextStyle(fontSize: 13)), Text("🎙️ Groq STT 音訊: ${(UsageTracker.groqAudioSeconds / 3600).toStringAsFixed(2)} 小時 (\$${groqCost.toStringAsFixed(3)})", style: const TextStyle(fontSize: 13)), Text("📝 Gemini 純文字請求: ${UsageTracker.geminiTextRequests} 次 (\$${geminiTextCost.toStringAsFixed(3)})", style: const TextStyle(fontSize: 13)), Text("🔊 Gemini 原生音訊: ${(UsageTracker.geminiAudioSeconds / 3600).toStringAsFixed(2)} 小時 (\$${geminiAudioCost.toStringAsFixed(3)})", style: const TextStyle(fontSize: 13)), const Divider(), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("目前累積成本 (約):"), Text("\$${totalCurrentCost.toStringAsFixed(3)} USD", style: const TextStyle(fontWeight: FontWeight.bold))]), const SizedBox(height: 4), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("預估 30 天月費:"), Text("\$${projectedMonthlyCost.toStringAsFixed(2)} USD", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red))])]))), const SizedBox(height: 20),
            
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.menu_book, color: Colors.purple, size: 36),
              title: const Text("字典與記憶庫管理", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              subtitle: const Text("管理預設與會者、專有名詞與錯字自動校正規則"),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                Navigator.push(context, MaterialPageRoute(builder: (context) => const DictionaryPage()));
              },
            ),
            const Divider(),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}

class DictionaryPage extends StatefulWidget {
  const DictionaryPage({super.key});
  @override
  State<DictionaryPage> createState() => _DictionaryPageState();
}

class _DictionaryPageState extends State<DictionaryPage> {
  final TextEditingController _participantController = TextEditingController();
  final TextEditingController _vocabController = TextEditingController();
  final TextEditingController _typoWrongController = TextEditingController();
  final TextEditingController _typoCorrectController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("字典與記憶庫管理")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text("預設與會者 (常用名單)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Row(
            children: [
              Expanded(child: TextField(controller: _participantController, decoration: const InputDecoration(hintText: "輸入姓名 (如: 小明)"))),
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
              children: list.map((name) => Chip(label: Text(name), onDeleted: () => GlobalManager.removeParticipant(name))).toList(),
            ),
          ),
          const SizedBox(height: 30),
          const Text("專有詞彙庫 (幫助 AI 辨識)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Row(
            children: [
              Expanded(child: TextField(controller: _vocabController, decoration: const InputDecoration(hintText: "輸入詞彙"))),
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
              children: list.map((word) => Chip(label: Text(word), onDeleted: () => GlobalManager.removeVocab(word))).toList(),
            ),
          ),
          const SizedBox(height: 30),
          const Text("錯字記憶庫 (AI 智能校正)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Text("當 AI 常把特定發音聽錯時，可設定強制取代 (例如: 頻狗 ➡️ 蘋果)", style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: TextField(controller: _typoWrongController, decoration: const InputDecoration(labelText: "常聽錯的字", border: OutlineInputBorder(), isDense: true))),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward)),
              Expanded(child: TextField(controller: _typoCorrectController, decoration: const InputDecoration(labelText: "正確字", border: OutlineInputBorder(), isDense: true))),
              IconButton(
                icon: const Icon(Icons.add_circle, color: Colors.blue, size: 36),
                onPressed: () {
                  final w = _typoWrongController.text.trim();
                  final c = _typoCorrectController.text.trim();
                  if (w.isNotEmpty && c.isNotEmpty) {
                    final list = List<String>.from(GlobalManager.typoListNotifier.value);
                    list.add("$w ➡️ $c");
                    GlobalManager.saveTypoList(list);
                    _typoWrongController.clear();
                    _typoCorrectController.clear();
                  }
                },
              )
            ],
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<List<String>>(
            valueListenable: GlobalManager.typoListNotifier,
            builder: (context, list, _) {
              return Wrap(
                spacing: 8, runSpacing: 8,
                children: list.map((item) {
                  return Chip(label: Text(item), deleteIcon: const Icon(Icons.cancel, size: 18), onDeleted: () { final newList = List<String>.from(list)..remove(item); GlobalManager.saveTypoList(newList); });
                }).toList(),
              );
            },
          ),
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
              GlobalManager.addLog("APP 啟動 (版本: $APP_VERSION)"); 
            },
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () async {
              try {
                final text = GlobalManager.logsNotifier.value.join('\n');
                if (text.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("沒有日誌可分享"))); return; }
                final dir = await getTemporaryDirectory();
                final file = File('${dir.path}/app_debug_log.txt');
                await file.writeAsString(text);
                await Share.shareXFiles([XFile(file.path)], text: 'Meeting Recorder Debug Log');
              } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("匯出失敗: $e"))); }
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final text = GlobalManager.logsNotifier.value.join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("日誌已複製到剪貼簿")));
            },
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: ValueListenableBuilder<List<String>>(
        valueListenable: GlobalManager.logsNotifier,
        builder: (context, logs, child) {
          if (logs.isEmpty) return const Center(child: Text("尚無日誌", style: TextStyle(color: Colors.white)));
          return ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: logs.length,
            separatorBuilder: (_, __) => const Divider(color: Colors.white24, height: 1),
            itemBuilder: (context, index) {
              final log = logs[index];
              Color textColor = Colors.greenAccent;
              if (log.contains("❌") || log.contains("失敗") || log.contains("Error") || log.contains("Exception") || log.contains("⚠️")) textColor = Colors.redAccent;
              else if (log.contains("Step") || log.contains("準備") || log.contains("YT狀態")) textColor = Colors.yellowAccent;
              return SelectableText(log, style: TextStyle(color: textColor, fontFamily: 'monospace', fontSize: 12));
            },
          );
        },
      ),
    );
  }
}
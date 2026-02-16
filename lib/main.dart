import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

// 狀態定義
enum NoteStatus { downloading, processing, success, failed }

// --- 資料模型 (增強防呆解析) ---
class TranscriptItem {
  String speaker;
  String text;
  double startTime;
  TranscriptItem(
      {required this.speaker, required this.text, this.startTime = 0.0});

  Map<String, dynamic> toJson() =>
      {'speaker': speaker, 'text': text, 'startTime': startTime};

  // 修改：改用 dynamic 接收，並處理字串例外
  factory TranscriptItem.fromJson(dynamic json) {
    if (json is String) return TranscriptItem(speaker: 'Unknown', text: json);
    if (json is Map) {
      double parsedTime = 0.0;
      var st = json['startTime'];
      if (st is num) {
        parsedTime = st.toDouble();
      } else if (st is String)
        parsedTime =
            double.tryParse(st.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
      return TranscriptItem(
        speaker: json['speaker']?.toString() ?? 'Unknown',
        text: json['text']?.toString() ?? '',
        startTime: parsedTime,
      );
    }
    return TranscriptItem(speaker: 'Unknown', text: '');
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

  // 修改：增強容錯
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

// --- 資料模型 (增強防呆解析與自訂狀態) ---
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
  String currentStep; // 紀錄當前處理進度文字

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
    this.currentStep = '', // 預設為空
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
        'currentStep': currentStep, // 儲存進度
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
      currentStep: json['currentStep']?.toString() ?? '', // 讀取進度
    );
  }
}

// --- 獨立的 REST API 處理類別 (修正網址與上傳邏輯) ---
// --- 輔助 Log 函式 (修改版) ---
void _log(String message) {
  // 將訊息存入 GlobalManager 讓手機畫面可以顯示
  GlobalManager.addLog(message);
}

// --- 獨立的 REST API 處理類別 (修正網址與 Resumable Upload) ---
class GeminiRestApi {
  static const String _baseUrl = 'https://generativelanguage.googleapis.com';

  static Future<Map<String, dynamic>> uploadFile(
    String apiKey,
    File file,
    String mimeType,
    String displayName,
  ) async {
    int fileSize = await file.length();
    _log('準備上傳 (Resumable): $displayName ($fileSize bytes)');

    final initUrl = Uri.parse(
        '$_baseUrl/upload/v1beta/files?key=$apiKey&uploadType=resumable');
    final metadata = jsonEncode({
      'file': {'display_name': displayName}
    });

    _log('Step 1: 初始化上傳請求...');
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

    _log('Step 2: 開始傳送檔案資料...');
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
      throw Exception(
          'File transfer failed (${uploadResponse.statusCode}): ${uploadResponse.body}');
    }

    final responseData = jsonDecode(uploadResponse.body);
    _log('✅ 上傳成功! File URI: ${responseData['file']['uri']}');
    return responseData['file'];
  }

  static Future<void> waitForFileActive(String apiKey, String fileName) async {
    final url = Uri.parse('$_baseUrl/v1beta/files/$fileName?key=$apiKey');
    _log('檢查狀態: $fileName');

    int retries = 0;
    while (retries < 60) {
      final response = await http.get(url);
      if (response.statusCode != 200) {
        throw Exception('Check status failed: ${response.body}');
      }

      final state = jsonDecode(response.body)['state'];
      _log('檔案狀態 ($retries): $state');

      if (state == 'ACTIVE') return;
      if (state == 'FAILED') throw Exception('File processing failed');

      await Future.delayed(const Duration(seconds: 2));
      retries++;
    }
    throw Exception('Timeout waiting for file to become ACTIVE');
  }

  static Future<String> generateContent(
    String apiKey,
    String modelName,
    String prompt,
    String fileUri,
    String mimeType,
  ) async {
    final url = Uri.parse(
        '$_baseUrl/v1beta/models/$modelName:generateContent?key=$apiKey');

    int retryCount = 0;
    int maxRetries = 5; // 增加最高重試次數

    while (true) {
      if (retryCount == 0) _log('發送 Prompt 至模型: $modelName');

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt},
                {
                  'file_data': {'mime_type': mimeType, 'file_uri': fileUri}
                }
              ]
            }
          ],
          'generationConfig': {'responseMimeType': 'application/json'}
        }),
      );

      // --- 核心修改：智慧擷取 Google 要求的等待時間並自動重試 ---
      if (response.statusCode == 429 && retryCount < maxRetries) {
        double waitSeconds = 20.0;
        // 透過正規表達式精準抓出 "retry in 47.5s." 的數字
        final match =
            RegExp(r'retry in (\d+(?:\.\d+)?)s').firstMatch(response.body);
        if (match != null && match.group(1) != null) {
          waitSeconds = double.parse(match.group(1)!) + 3.0; // 多加 3 秒緩衝，確保解鎖
        } else {
          waitSeconds = 20.0 * (retryCount + 1); // 備用機制
        }
        _log(
            "⚠️ 觸發 API 頻率限制 (429)，自動等待 ${waitSeconds.toInt()} 秒後重試 (第 ${retryCount + 1} 次)...");
        await Future.delayed(Duration(seconds: waitSeconds.toInt()));
        retryCount++;
        continue; // 重新執行 while 迴圈發送請求
      }

      if (response.statusCode != 200) {
        throw Exception('Generate content failed: ${response.body}');
      }

      try {
        return jsonDecode(response.body)['candidates'][0]['content']['parts'][0]
            ['text'];
      } catch (e) {
        throw Exception('Unexpected response format: ${response.body}');
      }
    }
  }

  // --- 純文字分析 (用於基於修改後逐字稿重新摘要) ---
  static Future<String> generateTextOnly(
      String apiKey, String modelName, String prompt) async {
    final url = Uri.parse(
        '$_baseUrl/v1beta/models/$modelName:generateContent?key=$apiKey');

    int retryCount = 0;
    int maxRetries = 5;

    while (true) {
      if (retryCount == 0) _log('發送純文字 Prompt 至模型: $modelName');

      final response = await http.post(
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
      );

      // --- 核心修改：智慧擷取 Google 要求的等待時間並自動重試 ---
      if (response.statusCode == 429 && retryCount < maxRetries) {
        double waitSeconds = 20.0;
        final match =
            RegExp(r'retry in (\d+(?:\.\d+)?)s').firstMatch(response.body);
        if (match != null && match.group(1) != null) {
          waitSeconds = double.parse(match.group(1)!) + 3.0;
        } else {
          waitSeconds = 20.0 * (retryCount + 1);
        }
        _log(
            "⚠️ 觸發 API 頻率限制 (429)，自動等待 ${waitSeconds.toInt()} 秒後重試 (第 ${retryCount + 1} 次)...");
        await Future.delayed(Duration(seconds: waitSeconds.toInt()));
        retryCount++;
        continue;
      }

      if (response.statusCode != 200) {
        throw Exception('Generate text failed: ${response.body}');
      }

      try {
        return jsonDecode(response.body)['candidates'][0]['content']['parts'][0]
            ['text'];
      } catch (e) {
        throw Exception('Unexpected response format: ${response.body}');
      }
    }
  }

  // --- 測試 API Key 並取得可用模型清單 ---
  static Future<List<String>> getAvailableModels(String apiKey) async {
    final url = Uri.parse('$_baseUrl/v1beta/models?key=$apiKey');
    _log('正在測試 API Key 並獲取模型清單...');
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
    _log('✅ 成功載入 ${availableModels.length} 個可用模型');
    return availableModels;
  }
}

// --- GlobalManager ---
class GlobalManager {
  static final ValueNotifier<bool> isRecordingNotifier = ValueNotifier(false);
  static final ValueNotifier<List<String>> vocabListNotifier =
      ValueNotifier([]);
  static final ValueNotifier<List<String>> participantListNotifier =
      ValueNotifier([]);
  static final ValueNotifier<List<String>> logsNotifier = ValueNotifier([]);

  // --- 用於即時更新首頁列表的推播器 ---
  static final ValueNotifier<List<MeetingNote>> notesNotifier =
      ValueNotifier([]);

  static void addLog(String message) {
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    final newLog = "[$time] [APP] $message";
    final currentLogs = logsNotifier.value;
    logsNotifier.value = currentLogs.length > 500
        ? [newLog, ...currentLogs.take(499)]
        : [newLog, ...currentLogs];
    print(newLog);
  }

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    vocabListNotifier.value = prefs.getStringList('vocab_list') ?? [];
    participantListNotifier.value =
        prefs.getStringList('participant_list') ?? [];
    await loadNotes(); // 初始化時自動載入一次筆記
  }

  // --- 將載入筆記獨立出來，並更新 Notifier ---
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
        notesNotifier.value = loaded; // 推播給首頁更新畫面
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

    // --- 每次存檔完自動刷新 Notifier ---
    await loadNotes();
  }

  static Future<void> deleteNote(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      List<MeetingNote> notes = (jsonDecode(existingJson) as List)
          .map((e) => MeetingNote.fromJson(e))
          .toList();
      notes.removeWhere((n) => n.id == id);
      await prefs.setString(
          'meeting_notes', jsonEncode(notes.map((e) => e.toJson()).toList()));

      // --- 每次刪除完自動刷新 Notifier ---
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

  // --- AI 分析核心 (強烈約束防幻覺版) ---
  static Future<void> analyzeNote(MeetingNote note) async {
    note.status = NoteStatus.processing;
    note.currentStep = "準備上傳檔案...";
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('api_key') ?? '';
    final modelName =
        prefs.getString('model_name') ?? 'gemini-1.5-flash-latest';
    final List<String> vocabList = vocabListNotifier.value;
    final List<String> participantList = participantListNotifier.value;

    try {
      if (apiKey.isEmpty) throw Exception("請先至設定頁面輸入 API Key");

      final audioFile = await getActualFile(note.audioPath);
      if (!await audioFile.exists()) {
        throw Exception("找不到音訊檔案: ${note.audioPath}");
      }

      _log("開始 Multipart 上傳...");
      note.currentStep = "上傳音訊檔案中...";
      await saveNote(note);

      final fileInfo = await GeminiRestApi.uploadFile(
          apiKey, audioFile, 'audio/mp4', note.title);
      final String fileUri = fileInfo['uri'];
      final String fileName = fileInfo['name'].split('/').last;
      await GeminiRestApi.waitForFileActive(apiKey, fileName);

      note.currentStep = "AI 正在分析會議摘要...";
      await saveNote(note);

      // --- 修正：嚴防預設名單污染摘要 ---
      String overviewPrompt = """
      你是一個專業的會議記錄助理。
      專有詞彙庫：${vocabList.join(', ')} (僅供聽寫校正參考)。
      預設與會者名單：${participantList.join(', ')} (⚠️最高警告：此名單僅供「人名正確寫法」的參考。絕對不可預設這些人有參與會議！若音訊中未明確提及此人，嚴禁將其寫入摘要或任務中)。
      
      【最高限制原則：絕對禁止憑空捏造！】
      1. 你的分析必須 100% 基於音訊內容。如果音訊是無聲、純雜音或無實質對話，你必須承認沒有內容。
      2. 若無實質內容，title 請寫「未偵測到有效對話」，summary 寫「無」，tasks 與 sections 給空陣列 []。
      3. 任務期限若無明確提及具體日期，必須填寫「未定」，嚴禁自己發明日期。
      
      請直接回傳純 JSON 格式，包含:
      - title (字串)
      - summary (字串陣列)
      - tasks (陣列，含 description, assignee, dueDate)
      - sections (陣列，含 title, startTime, endTime)
      - totalDuration (數字，總秒數)
      """;

      final overviewResponseText = await GeminiRestApi.generateContent(
          apiKey, modelName, overviewPrompt, fileUri, 'audio/mp4');
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

      double totalDuration = 600.0;
      var td = overviewJson['totalDuration'];
      if (td is num) {
        totalDuration = td.toDouble();
      } else if (td is String) totalDuration = double.tryParse(td) ?? 600.0;

      List<TranscriptItem> fullTranscript = [];
      int chunkSizeMin = 10;
      int totalChunks = (totalDuration / (chunkSizeMin * 60)).ceil();
      if (totalChunks <= 0) totalChunks = 1;

      for (int i = 0; i < totalChunks; i++) {
        note.currentStep = "分析逐字稿 (${i + 1}/$totalChunks)...";
        await saveNote(note);
        _log(note.currentStep);

        // --- 核心修正：強化聽打準確度、說話者辨識與多語系動態翻譯規則 ---
        String transcriptPrompt = """
        請扮演一位極度專業的「逐字稿聽打員」，針對 ${i * 10} 分鐘到 ${(i + 1) * 10} 分鐘的音訊提供一字不漏的逐字稿。
        
        【最高指導原則】：
        1. 嚴禁憑空捏造！若該段時間無人說話、只有環境音，請直接回傳空陣列 []。
        2. 忠實還原：請勿擅自摘要、潤飾或刪減對話。即便是贅詞、停頓語氣也請盡量保留，以還原真實對話情境。
        3. 精準辨識講者：請敏銳地根據音色、語氣、遠近與對話輪替，嚴格區分不同的說話者。若遇搶話或發言中斷，請精準斷句並給予不同的 speaker 標籤（如 Speaker A, Speaker B）。
        
        【精準辨識講者防錯機制】(極重要)：
        請敏銳地根據「音色」、「語氣」與「對話邏輯」來區分說話者。
        ⚠️ 致命陷阱警告：當說話者 A 提到 B 的名字，或是 A 在模仿 B 講話時，說話者依然是 A！絕對不可因為聽到 B 的名字，就誤判為 B 在發言。
        
        【多語系與翻譯規則】(極重要)：
        1. 若對話中僅夾雜「非中文單字/詞彙」，請保留原文，並在後方用括號附上繁體中文翻譯。範例：「這個 project (專案) 要確認。」
        2. 若「整句話」都是非中文（如全日文、全韓文、全英文），請務必嚴格依照以下「三行格式」輸出，不要省略任何一行：
           [原文] {外語原本的文字，如日文漢字/假名、韓文諺文等}
           [拼音] {對應的羅馬拼音 (Romaji/Pinyin) 或發音提示}
           [翻譯] {繁體中文翻譯}
           (範例)：
           [原文] 本当にありがとうございます
           [拼音] Hontou ni arigatou gozaimasu
           [翻譯] 真的非常感謝

        回傳純 JSON 陣列格式範例：
        [{"speaker":"A", "text":"你好", "startTime": 12.5}]
        """;

        // --- 核心修改：移除舊版寫死的迴圈，現在由 GeminiRestApi 智慧處理重試 ---
        try {
          final chunkResponseText = await GeminiRestApi.generateContent(
              apiKey, modelName, transcriptPrompt, fileUri, 'audio/mp4');
          final List<dynamic> chunkList = _parseJsonList(chunkResponseText);
          fullTranscript.addAll(
              chunkList.map((e) => TranscriptItem.fromJson(e)).toList());
        } catch (e) {
          _log("分段 $i 最終分析失敗: $e");
          // 遇到非 429 的嚴重錯誤，或超過 5 次重試依然失敗，紀錄後繼續處理下一段，不讓整筆中斷
        }

        // 基本的預防性延遲
        if (i < totalChunks - 1) {
          await Future.delayed(const Duration(seconds: 4));
        }
      }

      note.transcript = fullTranscript;
      note.status = NoteStatus.success;
      note.currentStep = ''; // 清空狀態
      await saveNote(note);
      _log("分析完成！");
    } catch (e) {
      _log("分析流程錯誤: $e");
      note.status = NoteStatus.failed;
      note.summary = ["分析失敗: $e"];
      note.currentStep = ''; // 清空狀態
      await saveNote(note);
    }
  }

  static Future<void> reSummarizeFromTranscript(MeetingNote note) async {
    note.status = NoteStatus.processing;
    note.currentStep = "基於最新逐字稿整理摘要...";
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('api_key') ?? '';
    final modelName =
        prefs.getString('model_name') ?? 'gemini-1.5-flash-latest';

    try {
      if (apiKey.isEmpty) throw Exception("請先設定 API Key");

      StringBuffer sb = StringBuffer();
      for (var t in note.transcript) {
        sb.writeln("[${t.startTime}秒] ${t.speaker}: ${t.text}");
      }
      String transcriptText = sb.toString();

      if (transcriptText.trim().isEmpty) throw Exception("逐字稿為空，無法摘要");

      String prompt = """
      以下是人工修訂後的會議逐字稿：
      ---
      $transcriptText
      ---
      請根據上方文字，重新整理會議摘要與任務。
      【最高限制原則：絕對禁止憑空捏造！】
      1. 內容必須 100% 來自上方文字，不可自行腦補。
      2. 任務期限若無明確提及具體日期，必須填寫「未定」。
      請回傳純 JSON 格式，包含:
      - title (字串)
      - summary (字串陣列)
      - tasks (陣列，含 description, assignee, dueDate)
      - sections (為上方逐字稿劃分大綱段落，含 title, startTime, endTime)
      """;

      final responseText =
          await GeminiRestApi.generateTextOnly(apiKey, modelName, prompt);
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
      } else if (cleanText.startsWith('```'))
        cleanText = cleanText.substring(3);
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
      } else if (cleanText.startsWith('```'))
        cleanText = cleanText.substring(3);
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

// --- MainAppShell ---
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
    // 確保權限
    Map<Permission, PermissionStatus> statuses = await [
      Permission.microphone,
    ].request();

    if (statuses[Permission.microphone]!.isGranted) {
      final dir = await getApplicationDocumentsDirectory();
      final fileName =
          "rec_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}_p$recordingPart.m4a";
      final path = '${dir.path}/$fileName';

      // --- 核心修正：將硬體降噪、單聲道、高解析參數完美整合進你的錄音配置中 ---
      await audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc, // 使用相容性最高、壓縮比好的 AAC 格式
          bitRate: 128000, // 確保音質清晰 (128kbps)
          sampleRate: 44100, // 標準音訊採樣率
          numChannels: 1, // 【關鍵】設定為單聲道 (Mono) 更利於 AI 語音辨識
          autoGain: true, // 【關鍵】開啟自動增益：讓小聲說話的人變大聲
          echoCancel: true, // 【關鍵】開啟回音消除：減少空曠會議室的回音
          noiseSuppress: true, // 【關鍵】開啟硬體降噪：過濾冷氣聲、風聲等背景底噪
        ),
        path: path,
      );
      // -----------------------------------------------------------------------

      stopwatch.reset();
      stopwatch.start();

      timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted) return;
        setState(() {
          timerText =
              "${stopwatch.elapsed.inMinutes.toString().padLeft(2, '0')}:${(stopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}";
        });

        final duration = stopwatch.elapsed;
        final amplitude = await audioRecorder.getAmplitude();
        final currentAmp = amplitude.current;

        // 保留你原本非常優秀的「智慧靜音分段」邏輯
        if ((duration.inMinutes >= 29 && currentAmp < -30) ||
            duration.inMinutes >= 30) {
          await handleAutoSplit();
        }
      });

      GlobalManager.isRecordingNotifier.value = true;
      GlobalManager.addLog("開始錄音，並已啟用硬體降噪與人聲增益...");
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
    // 解決 Android 13+ 權限問題
    Map<Permission, PermissionStatus> statuses = await [
      Permission.storage,
      Permission.audio, // Android 13+
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
        } catch (e) {
          print("無法取得檔案時間: $e");
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

// --- 整合版 YouTube 匯入與備用串流下載機制 ---
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
      await GlobalManager.saveNote(note); // 建立初始紀錄，讓首頁顯示進度
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
        // --- 核心修正：自動迴圈嘗試各種可用串流，對抗 DNS 與被阻擋的來源 ---
        for (var streamInfo in audioStreams) {
          try {
            var stream = yt.videos.streamsClient.get(streamInfo);
            final dir = await getApplicationDocumentsDirectory();
            audioFile = File('${dir.path}/${video.id}.mp4');
            var fileStream = audioFile.openWrite();

            // 加上 timeout：如果 45 秒內沒下載完就強制切斷，嘗試下一個來源！
            await stream.pipe(fileStream).timeout(const Duration(seconds: 45));
            await fileStream.flush();
            await fileStream.close();
            break; // 成功下載即跳出
          } catch (e) {
            GlobalManager.addLog("YT音訊串流失敗，嘗試下一個: $e");
            audioFile = null;
          }
        }

        // 若純音訊都失敗，改拿包含影像的串流做備用
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
                  .timeout(const Duration(seconds: 60)); // 影音檔較大，給 60 秒
              await fileStream.flush();
              await fileStream.close();
              break;
            } catch (e) {
              GlobalManager.addLog("備用串流失敗或超時: $e");
              audioFile = null;
            }
          }
        }

        if (audioFile == null || !(await audioFile.exists())) {
          throw Exception("無法下載該影片，來源可能受到地區或版權限制。");
        }
        // -----------------------------------------------------------

        note.audioPath = audioFile.path;
        note.currentStep = '準備進行 AI 分析...';
        await GlobalManager.saveNote(note);

        GlobalManager.analyzeNote(note);
      } catch (e) {
        GlobalManager.addLog("YT處理失敗: $e");
        note.status = NoteStatus.failed;
        note.summary = ["下載失敗: $e\n(請檢查網路連線或影片版權限制)"];
        note.currentStep = '';
        await GlobalManager.saveNote(note);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text("YouTube 載入失敗: $e")));
        }
      } finally {
        yt.close();
      }
    }
  }

// --- 底部彈出選單 (錄音/匯入選項) ---
  void showAddMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            // --- 補回開始錄音按鈕 ---
            ListTile(
              leading: const Icon(Icons.mic, color: Colors.green),
              title: const Text('開始錄音'),
              onTap: () {
                Navigator.pop(context);
                toggleRecording(); // 呼叫原本的錄音開關
              },
            ),
            // ------------------------
            ListTile(
              leading: const Icon(Icons.file_upload, color: Colors.blue),
              title: const Text('匯入本地錄音/音檔'),
              onTap: () {
                Navigator.pop(context);
                // 💡 注意：請確認你原本處理選擇檔案的函數名稱是什麼
                // 如果你的函數叫做 pickFile() 或 importFile()，請改為對應名稱
                pickFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.ondemand_video, color: Colors.red),
              title: const Text('匯入 YouTube 影片'),
              onTap: () {
                Navigator.pop(context);
                importYoutube(); // 呼叫我們剛剛寫好的 YT 匯入功能
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
    // 初始載入交給 GlobalManager
    GlobalManager.loadNotes();
  }

  Future<void> togglePin(MeetingNote note) async {
    note.isPinned = !note.isPinned;
    await GlobalManager.saveNote(note); // 存檔後 GlobalManager 會自動推播更新
  }

  Future<void> deleteNote(String id) async {
    await GlobalManager.deleteNote(id); // 刪除後 GlobalManager 會自動推播更新
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("會議記錄列表"), centerTitle: true),
      // --- 綁定 notesNotifier，只要資料庫有變更，這裡自動重繪！ ---
      body: ValueListenableBuilder<List<MeetingNote>>(
          valueListenable: GlobalManager.notesNotifier,
          builder: (context, notes, child) {
            return RefreshIndicator(
              onRefresh: GlobalManager.loadNotes, // 下拉重整
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
                          // --- 保留之前加入的確認刪除防呆 ---
                          confirmDismiss: (direction) async {
                            return await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text("確定要刪除嗎？"),
                                content: const Text("此操作將永久刪除該筆會議紀錄，無法復原。"),
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
                                  // --- 動態顯示分析與下載狀態 ---
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
                                // 返回後自動刷新
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

  // 用於逐字稿捲動與高亮控制
  final ScrollController _transcriptScrollController = ScrollController();
  final Map<int, GlobalKey> _transcriptKeys = {};
  int _currentActiveTranscriptIndex = -1;

  // 新增：紀錄被收合的章節標題
  final Set<String> _collapsedSections = {};

  // --- 新增：多語系顯示開關 ---
  bool _showOriginal = true;
  bool _showPhonetic = true;
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

        // --- 核心邏輯：自動高亮、自動展開與捲動 ---
        if (_tabController.index == 1 && _note.transcript.isNotEmpty) {
          int newIndex = _note.transcript
              .lastIndexWhere((t) => p.inSeconds >= t.startTime);
          if (newIndex != -1 && newIndex != _currentActiveTranscriptIndex) {
            setState(() {
              _currentActiveTranscriptIndex = newIndex;

              // 若播放到了被收合的章節，自動將其展開
              try {
                Section activeSec = _note.sections.lastWhere(
                    (s) => _note.transcript[newIndex].startTime >= s.startTime);
                if (_collapsedSections.contains(activeSec.title)) {
                  _collapsedSections.remove(activeSec.title);
                }
              } catch (e) {}
            });

            // 使用 PostFrameCallback 確保 UI 渲染完成後才進行捲動，避免跳轉失敗
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_transcriptKeys.containsKey(newIndex) &&
                  _transcriptKeys[newIndex]!.currentContext != null) {
                Scrollable.ensureVisible(
                  _transcriptKeys[newIndex]!.currentContext!,
                  duration: const Duration(milliseconds: 300),
                  alignment: 0.3, // 捲動到畫面約 30% 高度的位置
                ).catchError((_) {}); // 忽略不可見時的錯誤
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

  // 修改：支援尚未點擊播放時的跳轉
  Future<void> _seekTo(double seconds) async {
    File actualFile = await GlobalManager.getActualFile(_note.audioPath);
    if (await actualFile.exists()) {
      // 如果還沒有載入過音檔 (duration為0)，先預先載入來源，這樣跳轉才有效
      if (_duration == Duration.zero && !_isPlaying) {
        await _audioPlayer.setSource(DeviceFileSource(actualFile.path));
      }
      await _audioPlayer.seek(Duration(seconds: seconds.toInt()));
    }
  }

  // 雙擊時直接跳轉並開始播放
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
            "您想如何重新分析？\n\n1. 【基於逐字稿】：保留您目前對逐字稿的修改，僅重新整理摘要與任務 (速度快)。\n\n2. 【語音重聽】：重新將錄音檔交給 AI 分析，會覆蓋現有所有資料。"),
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
        TextEditingController(text: _note.transcript[index].text);

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

                // --- 修改：游標斷句按鈕 (加入智慧時間推算) ---
                IconButton(
                  icon: const Icon(Icons.call_split, color: Colors.blue),
                  tooltip: "從游標處斷開為兩句",
                  onPressed: () {
                    int pos = controller.selection.baseOffset;
                    if (pos > 0 && pos < controller.text.length) {
                      String part1 = controller.text.substring(0, pos).trim();
                      String part2 = controller.text.substring(pos).trim();

                      // --- 核心修改：智慧計算新秒數 ---
                      double currentStartTime =
                          _note.transcript[index].startTime;
                      // 取得下一句的時間，如果沒有下一句，就預設加 5 秒
                      double nextStartTime = currentStartTime + 5.0;
                      if (index + 1 < _note.transcript.length) {
                        nextStartTime = _note.transcript[index + 1].startTime;
                      }

                      // 根據切斷位置佔整句話的比例，推算第二句的起始時間
                      double ratio = pos / controller.text.length;
                      double newStartTime = currentStartTime +
                          ((nextStartTime - currentStartTime) * ratio);

                      setState(() {
                        _note.transcript[index].text = part1;
                        _note.transcript.insert(
                          index + 1,
                          TranscriptItem(
                            speaker: _note.transcript[index].speaker,
                            text: part2,
                            // 將計算出的新時間，取到小數點第一位
                            startTime:
                                double.parse(newStartTime.toStringAsFixed(1)),
                          ),
                        );
                      });
                      _saveNoteUpdate();
                      Navigator.pop(dialogContext);
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("已斷開並自動推算新時間！")));
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
                _note.transcript[index].text = controller.text;
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

      // --- 核心修正：強制寫入 UTF-8 BOM，徹底解決 Windows/Excel 開啟的亂碼問題 ---
      List<int> bytes = [];
      if (ext == 'csv' || ext == 'md') {
        bytes.addAll([0xEF, 0xBB, 0xBF]); // 加入 UTF-8 BOM 標記
      }
      bytes.addAll(utf8.encode(content));
      await file.writeAsBytes(bytes);
      // -----------------------------------------------------------------------

      await Share.shareXFiles([XFile(file.path)],
          text: '會議記錄匯出: ${_note.title}');
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("匯出失敗: $e")));
    }
  }

  Future<void> _exportCsv() async {
    StringBuffer csv = StringBuffer();
    // 寫入標題與日期
    csv.writeln("會議標題,${_note.title.replaceAll('"', '""')}");
    csv.writeln("會議日期,${DateFormat('yyyy/MM/dd HH:mm').format(_note.date)}\n");

    // 寫入摘要
    csv.writeln("【重點摘要】");
    for (var s in _note.summary) {
      csv.writeln('"${s.replaceAll('"', '""')}"');
    }
    csv.writeln("");

    // 寫入任務
    csv.writeln("【待辦事項】");
    csv.writeln("任務,負責人,期限");
    for (var t in _note.tasks) {
      csv.writeln(
          '"${t.description.replaceAll('"', '""')}","${t.assignee}","${t.dueDate}"');
    }
    csv.writeln("");

    // 寫入逐字稿
    csv.writeln("【逐字稿】");
    csv.writeln("時間,說話者,內容");
    for (var item in _note.transcript) {
      String time = DateFormat('HH:mm:ss')
          .format(DateTime(0).add(Duration(seconds: item.startTime.toInt())));
      String text = item.text.replaceAll('"', '""');
      csv.writeln('$time,${item.speaker},"$text"');
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
      String time = DateFormat('mm:ss')
          .format(DateTime(0).add(Duration(seconds: item.startTime.toInt())));
      md.writeln("**$time [${item.speaker}]**: ${item.text}\n");
    }
    await _exportFile('md', md.toString());
  }

  Future<void> _generatePdf() async {
    final pdf = pw.Document();

    // --- 1. 原本的字體 ---
    final fontRegular = await PdfGoogleFonts.notoSansTCRegular();
    final fontBold = await PdfGoogleFonts.notoSansTCBold();

    // --- 2. 新增：載入韓文專用字體 ---
    final fontKorean = await PdfGoogleFonts.notoSansKRRegular();

    pdf.addPage(
      pw.MultiPage(
        // --- 3. 修改：加入 fontFallback 陣列 ---
        theme: pw.ThemeData.withFont(
          base: fontRegular,
          bold: fontBold,
          fontFallback: [fontKorean], // 👈 當 TC 找不到字時，自動用韓文字體補上
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
                      child: pw.Text(
                          DateFormat('mm:ss').format(DateTime(0)
                              .add(Duration(seconds: t.startTime.toInt()))),
                          style: const pw.TextStyle(color: PdfColors.grey))),
                  pw.SizedBox(
                      width: 60,
                      child: pw.Text(t.speaker,
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(child: pw.Text(t.text)),
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
                    "${_position.inMinutes}:${(_position.inSeconds % 60).toString().padLeft(2, '0')} / ${_duration.inMinutes}:${(_duration.inSeconds % 60).toString().padLeft(2, '0')}"),
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
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text("AI 正在努力分析中...")
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

  // --- 新增：智慧解析多語系文字並依開關顯示 ---
  Widget _buildParsedText(String text) {
    // 如果不是外語三行格式，就當作一般中文直接顯示
    if (!text.contains('[原文]') &&
        !text.contains('[拼音]') &&
        !text.contains('[翻譯]')) {
      return Text(text, style: const TextStyle(fontSize: 16));
    }

    List<Widget> widgets = [];
    for (var line in text.split('\n')) {
      String trimmed = line.trim();
      if (trimmed.startsWith('[原文]')) {
        if (_showOriginal) {
          widgets.add(Text(trimmed,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)));
        }
      } else if (trimmed.startsWith('[拼音]')) {
        if (_showPhonetic) {
          widgets.add(Text(trimmed,
              style: const TextStyle(
                  fontSize: 14,
                  color: Colors.blueGrey,
                  fontStyle: FontStyle.italic)));
        }
      } else if (trimmed.startsWith('[翻譯]')) {
        if (_showTranslation) {
          widgets.add(Text(trimmed,
              style: TextStyle(fontSize: 16, color: Colors.green.shade700)));
        }
      } else if (trimmed.isNotEmpty) {
        // 捕捉 AI 偶爾多講的廢話或無標籤的句子
        widgets.add(Text(trimmed,
            style: TextStyle(fontSize: 16, color: Colors.green.shade700)));
      }
    }

    // 如果使用者把三個開關都關掉，至少顯示個提示
    if (widgets.isEmpty) {
      return const Text("...", style: TextStyle(color: Colors.grey));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  // --- 改良版：帶有章節歸屬與動態高亮的逐字稿列表 ---
  Widget _buildTranscriptTab() {
    List<Widget> listItems = [];
    // --- 新增：多語系顯示切換列 (置於逐字稿最上方) ---
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
              const Text("多語系顯示：",
                  style: TextStyle(
                      fontSize: 14,
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

    // --- 新增：智慧大頭貼縮寫邏輯 ---
    String getSpeakerAvatarChar(String name) {
      if (name.isEmpty) return "?";
      String cleanName = name.trim();

      // 1. 處理 "Speaker A", "Speaker B" -> 取最後的字母 A 或 B
      if (cleanName.toLowerCase().startsWith('speaker ')) {
        return cleanName.split(' ').last[0].toUpperCase();
      }
      // 2. 處理中文名字 -> 取最後一個字 (如「家偉」->「偉」, 「李四」->「四」)
      if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(cleanName) &&
          cleanName.length >= 2) {
        return cleanName.substring(cleanName.length - 1);
      }
      // 3. 處理英文全名 -> 取最後一個單字的首字母 (如 "John Doe" -> "D")
      if (cleanName.contains(' ')) {
        return cleanName.split(' ').last[0].toUpperCase();
      }
      // 4. 預設取第一個字
      return cleanName[0].toUpperCase();
    }
    // ---------------------------------

    for (int i = 0; i < _note.transcript.length; i++) {
      final item = _note.transcript[i];

      Section? sec;
      try {
        sec = _note.sections.lastWhere((s) => item.startTime >= s.startTime);
      } catch (e) {
        sec = null;
      }

      // 1. 章節標題
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

      // 2. 被收合的章節隱藏對話
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
                    // --- 修改：套用智慧縮寫函數 ---
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
                        // --- 核心修正：將原本單純的 Text 替換為支援開關的多語系文字解析器 ---
                        _buildParsedText(item.text),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('mm:ss').format(DateTime(0)
                        .add(Duration(seconds: item.startTime.toInt()))),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 改用 SingleChildScrollView + Column 確保所有 GlobalKey 都有 Context，跳轉絕對不會失敗
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
            subtitle:
                Text("${(section.endTime - section.startTime).toInt()} 秒"),
            leading: const Icon(Icons.bookmark),
            onTap: () {
              // 1. 確保該章節已展開
              setState(() {
                _collapsedSections.remove(section.title);
              });

              // 2. 切換回「逐字稿」頁籤
              _tabController.animateTo(1);

              // --- 核心修正：找出確切的逐字稿索引，等待 Tab 動畫完成後強制捲動 ---
              int targetIndex = _note.transcript
                  .indexWhere((t) => t.startTime >= section.startTime);
              if (targetIndex != -1) {
                setState(() => _currentActiveTranscriptIndex = targetIndex);

                // --- 核心修正：加入智慧重試機制與頂部聚焦對齊 ---
                void tryScroll(int retries) {
                  if (!mounted) return;
                  final ctx = _transcriptKeys[targetIndex]?.currentContext;

                  if (ctx != null) {
                    Scrollable.ensureVisible(
                      ctx,
                      duration: const Duration(milliseconds: 300),
                      alignment: 0.1, // 改為 0.1，讓目標對話更靠近螢幕頂部，達成完美聚焦
                    ).catchError((_) {});
                  } else if (retries > 0) {
                    // 若 Context 還沒準備好 (Tab可能還在切換動畫)，延遲 100ms 後再次嘗試
                    Future.delayed(const Duration(milliseconds: 100),
                        () => tryScroll(retries - 1));
                  }
                }

                // 先給 100ms 讓 Tab 開始切換，接著最多自動重試 10 次 (約 1 秒)，保證捲動一定成功
                Future.delayed(
                    const Duration(milliseconds: 100), () => tryScroll(10));
              }

              // 3. 跳轉音訊並播放
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
  final TextEditingController _vocabController = TextEditingController();
  final TextEditingController _participantController = TextEditingController();

  String _selectedModel = 'gemini-flash-latest';
  List<String> _models = ['gemini-flash-latest']; // 初始預設選項
  bool _isLoadingModels = false; // 控制載入中動畫

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text = prefs.getString('api_key') ?? '';
      String savedModel =
          prefs.getString('model_name') ?? 'gemini-flash-latest';

      // 防呆：確保儲存的模型存在於當前的清單中，否則 Dropdown 會報錯
      if (!_models.contains(savedModel)) {
        _models.add(savedModel);
      }
      _selectedModel = savedModel;
    });
  }

  // --- 測試與載入模型邏輯 ---
  Future<void> _testAndLoadModels() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text("請先輸入 API Key", style: TextStyle(color: Colors.white)),
            backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() => _isLoadingModels = true);

    try {
      List<String> fetchedModels =
          await GeminiRestApi.getAvailableModels(apiKey);

      if (fetchedModels.isEmpty) {
        throw Exception("此 API Key 沒有找到支援生成的 Gemini 模型");
      }

      setState(() {
        _models = fetchedModels;
        // 依照需求：優先預設為 gemini-flash-latest
        if (_models.contains('gemini-flash-latest')) {
          _selectedModel = 'gemini-flash-latest';
        } else if (_models.contains('gemini-1.5-flash-latest')) {
          _selectedModel = 'gemini-1.5-flash-latest';
        } else {
          _selectedModel = _models.first;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("✅ API Key 測試成功！已載入最新模型清單"),
            backgroundColor: Colors.green),
      );

      // 測試成功順便存檔
      _saveSettings();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("❌ 測試失敗: $e"), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isLoadingModels = false);
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text);
    await prefs.setString('model_name', _selectedModel);

    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("設定已儲存")));
    }
  }

  @override
  Widget build(BuildContext context) {
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
            "API 設定",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          TextField(
            controller: _apiKeyController,
            decoration: const InputDecoration(
              labelText: "Gemini API Key",
              hintText: "輸入您的 API Key",
            ),
            obscureText: true,
          ),
          const SizedBox(height: 10),

          // --- 測試 API Key 的按鈕 ---
          ElevatedButton.icon(
            onPressed: _isLoadingModels ? null : _testAndLoadModels,
            icon: _isLoadingModels
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: Text(_isLoadingModels ? "連線測試中..." : "測試 API Key 並載入模型"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade50,
              foregroundColor: Colors.green.shade800,
            ),
          ),
          const SizedBox(height: 10),

          // 使用 InputDecorator + DropdownButton 完美避開棄用警告，且支援動態更新
          InputDecorator(
            decoration: const InputDecoration(labelText: "選擇 AI 模型"),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedModel,
                isExpanded: true,
                items: _models
                    .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                    .toList(),
                onChanged: (val) => setState(() => _selectedModel = val!),
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
          const SizedBox(height: 30),
          ElevatedButton(
            onPressed: _saveSettings,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
            ),
            child: const Text("儲存所有設定"),
          ),
        ],
      ),
    );
  }
}

// --- 日誌檢視頁面 (增強版：加入分享功能) ---
class LogViewerPage extends StatelessWidget {
  const LogViewerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("系統日誌 (Debug)"),
        actions: [
          // 1. 清除按鈕
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              GlobalManager.logsNotifier.value = []; // 清空日誌
            },
          ),
          // 2. 分享按鈕
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

                // 取得暫存目錄
                final dir = await getTemporaryDirectory();
                final file = File('${dir.path}/app_debug_log.txt');

                // 寫入檔案
                await file.writeAsString(text);

                // 呼叫系統分享
                await Share.shareXFiles([XFile(file.path)],
                    text: 'Meeting Recorder Debug Log');
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("匯出失敗: $e")),
                );
              }
            },
          ),
          // 3. 複製按鈕
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
      backgroundColor: Colors.black, // 黑底更有工程師感
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
              Color textColor = Colors.greenAccent; // 一般訊息顏色
              if (log.contains("❌") ||
                  log.contains("失敗") ||
                  log.contains("Error") ||
                  log.contains("Exception")) {
                textColor = Colors.redAccent; // 錯誤訊息顏色
              } else if (log.contains("Step") || log.contains("準備")) {
                textColor = Colors.yellowAccent; // 步驟顏色
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

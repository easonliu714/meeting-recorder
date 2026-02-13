import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http; // <--- 新增這行
// import 'package:google_generative_ai/google_generative_ai.dart'; // 建議註解掉，改用純 HTTP
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

// --- 資料模型 ---
class TranscriptItem {
  String speaker;
  String text;
  double startTime;
  TranscriptItem({
    required this.speaker,
    required this.text,
    this.startTime = 0.0,
  });
  Map<String, dynamic> toJson() => {
        'speaker': speaker,
        'text': text,
        'startTime': startTime,
      };
  factory TranscriptItem.fromJson(Map<String, dynamic> json) => TranscriptItem(
        speaker: json['speaker'] ?? 'Unknown',
        text: json['text'] ?? '',
        startTime: (json['startTime'] ?? 0.0).toDouble(),
      );
}

class TaskItem {
  String description;
  String assignee;
  String dueDate;
  TaskItem({
    required this.description,
    this.assignee = '未定',
    this.dueDate = '未定',
  });
  Map<String, dynamic> toJson() => {
        'description': description,
        'assignee': assignee,
        'dueDate': dueDate,
      };
  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
        description: json['description'] ?? '',
        assignee: json['assignee'] ?? '未定',
        dueDate: json['dueDate'] ?? '未定',
      );
}

class Section {
  String title;
  double startTime;
  double endTime;
  Section({
    required this.title,
    required this.startTime,
    required this.endTime,
  });
  Map<String, dynamic> toJson() => {
        'title': title,
        'startTime': startTime,
        'endTime': endTime,
      };
  factory Section.fromJson(Map<String, dynamic> json) => Section(
        title: json['title'] ?? '未命名段落',
        startTime: (json['startTime'] ?? 0.0).toDouble(),
        endTime: (json['endTime'] ?? 0.0).toDouble(),
      );
}

class MeetingNote {
  String id;
  String title;
  DateTime date;
  List<String> summary;
  List<TaskItem> tasks;
  List<TranscriptItem> transcript;
  List<Section> sections;
  String audioPath;
  NoteStatus status;
  bool isPinned;

  MeetingNote({
    required this.id,
    required this.title,
    required this.date,
    required this.summary,
    required this.tasks,
    required this.transcript,
    required this.sections,
    required this.audioPath,
    this.status = NoteStatus.success,
    this.isPinned = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'date': date.toIso8601String(),
        'summary': summary,
        'tasks': tasks.map((e) => e.toJson()).toList(),
        'transcript': transcript.map((e) => e.toJson()).toList(),
        'sections': sections.map((e) => e.toJson()).toList(),
        'audioPath': audioPath,
        'status': status.index,
        'isPinned': isPinned,
      };

  factory MeetingNote.fromJson(Map<String, dynamic> json) => MeetingNote(
        id: json['id'],
        title: json['title'],
        date: DateTime.parse(json['date']),
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
        audioPath: json['audioPath'] ?? '',
        status: NoteStatus.values[json['status'] ?? 2],
        isPinned: json['isPinned'] ?? false,
      );
}

// --- 獨立的 REST API 處理類別 (修正網址與上傳邏輯) ---
class GeminiRestApi {
  static const String _host = 'generativeai.googleapis.com';

  static Future<Map<String, dynamic>> uploadFile(
    String apiKey,
    File file,
    String mimeType,
    String displayName,
  ) async {
    int fileSize = await file.length();

    // 1. 建立初始上傳請求 (Resumable Upload)
    // 注意：上傳的 path 必須包含 /upload/
    final initUrl = Uri.https(_host, '/upload/v1beta/files', {'key': apiKey});

    final initResponse = await http.post(
      initUrl,
      headers: {
        'X-Goog-Upload-Protocol': 'resumable',
        'X-Goog-Upload-Command': 'start',
        'X-Goog-Upload-Header-Content-Length': fileSize.toString(),
        'X-Goog-Upload-Header-Content-Type': mimeType,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'file': {'display_name': displayName}
      }),
    );

    if (initResponse.statusCode != 200) {
      throw Exception(
          'Upload init failed (${initResponse.statusCode}): ${initResponse.body}');
    }

    // 取得實際的上傳網址
    final uploadUrlHeader = initResponse.headers['x-goog-upload-url'];
    if (uploadUrlHeader == null)
      throw Exception('No upload URL returned from Google');

    // 2. 上傳實際檔案 bytes
    final bytes = await file.readAsBytes();
    final uploadResponse = await http.put(
      Uri.parse(uploadUrlHeader),
      headers: {
        'Content-Length': fileSize.toString(),
        'X-Goog-Upload-Offset': '0',
        'X-Goog-Upload-Command': 'upload, finalize',
      },
      body: bytes,
    );

    if (uploadResponse.statusCode != 200) {
      throw Exception(
          'File upload failed (${uploadResponse.statusCode}): ${uploadResponse.body}');
    }

    // 回傳 file 物件資訊
    return jsonDecode(uploadResponse.body)['file'];
  }

  static Future<void> waitForFileActive(String apiKey, String fileName) async {
    // 查詢狀態的 path 不需要 /upload/
    final uri = Uri.https(_host, '/v1beta/files/$fileName', {'key': apiKey});

    int retries = 0;
    while (retries < 60) {
      // 最多等 2 分鐘
      final response = await http.get(uri);
      if (response.statusCode != 200)
        throw Exception('Get file status failed: ${response.body}');

      final state = jsonDecode(response.body)['state'];
      print("File state: $state");

      if (state == 'ACTIVE') return;
      if (state == 'FAILED')
        throw Exception('File processing failed state: $state');

      await Future.delayed(const Duration(seconds: 2));
      retries++;
    }
    throw Exception(
        'File processing timed out (still processing after 2 mins)');
  }

  static Future<String> generateContent(
    String apiKey,
    String modelName,
    String prompt,
    String fileUri,
    String mimeType,
  ) async {
    // 生成內容的 path
    final uri = Uri.https(
        _host, '/v1beta/models/$modelName:generateContent', {'key': apiKey});

    final response = await http.post(
      uri,
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
        ]
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Generate content failed (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body);
    try {
      return data['candidates'][0]['content']['parts'][0]['text'];
    } catch (e) {
      throw Exception('Unexpected API response format: $data');
    }
  }
}

// --- GlobalManager ---
class GlobalManager {
  static final ValueNotifier<bool> isRecordingNotifier = ValueNotifier(false);
  static final ValueNotifier<List<String>> vocabListNotifier =
      ValueNotifier([]);
  static final ValueNotifier<List<String>> participantListNotifier =
      ValueNotifier([]);

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    vocabListNotifier.value = prefs.getStringList('vocab_list') ?? [];
    participantListNotifier.value =
        prefs.getStringList('participant_list') ?? [];
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
      } catch (e) {
        print("Error parsing notes: $e");
      }
    }
    int index = notes.indexWhere((n) => n.id == note.id);
    if (index != -1) {
      notes[index] = note;
    } else {
      notes.add(note);
    }
    await prefs.setString(
      'meeting_notes',
      jsonEncode(notes.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> deleteNote(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      try {
        List<MeetingNote> notes = (jsonDecode(existingJson) as List)
            .map((e) => MeetingNote.fromJson(e))
            .toList();
        notes.removeWhere((n) => n.id == id);
        await prefs.setString(
          'meeting_notes',
          jsonEncode(notes.map((e) => e.toJson()).toList()),
        );
      } catch (e) {
        print("Error deleting note: $e");
      }
    }
  }

// --- AI 分析 (修正：使用 GeminiRestApi 避免 SDK 版本問題與 404) ---
  static Future<void> analyzeNote(MeetingNote note) async {
    note.status = NoteStatus.processing;
    note.summary = ["準備上傳檔案..."];
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('api_key') ?? '';
    // 預設模型：若未設定則使用 gemini-1.5-flash
    final modelName = prefs.getString('model_name') ?? 'gemini-1.5-flash';
    final List<String> vocabList = vocabListNotifier.value;
    final List<String> participantList = participantListNotifier.value;

    try {
      if (apiKey.isEmpty) throw Exception("請先至設定頁面輸入 API Key");

      final audioFile = File(note.audioPath);
      if (!await audioFile.exists())
        throw Exception("找不到音訊檔案 (路徑: ${note.audioPath})");

      // 1. 上傳檔案 (REST API)
      print("開始上傳檔案 (REST API)...");
      final fileInfo = await GeminiRestApi.uploadFile(
          apiKey, audioFile, 'audio/mp4', note.title);

      final String fileUri = fileInfo['uri'];
      final String fileName =
          fileInfo['name'].split('/').last; // 取得 files/ 後面的 ID

      print("等待檔案處理: $fileName");
      await GeminiRestApi.waitForFileActive(apiKey, fileName);

      // 2. 第一階段：概覽分析
      note.summary = ["AI 正在分析會議摘要 ($modelName)..."];
      await saveNote(note);

      String overviewPrompt = """
      你是一個專業的會議記錄助理。
      專有詞彙庫：${vocabList.join(', ')}。
      預設與會者名單：${participantList.join(', ')}。
      
      請分析整個音訊檔，並回傳純 JSON 格式 (不要 Markdown)。
      你需要回傳以下欄位：
      {
        "title": "會議標題",
        "summary": ["重點摘要1", "重點摘要2"],
        "tasks": [{"description": "待辦事項", "assignee": "負責人", "dueDate": "YYYY-MM-DD"}],
        "sections": [{"title": "議題一", "startTime": 0.0, "endTime": 120.0}],
        "totalDuration": 300.0 (音訊總秒數，請務必精準估算)
      }
      注意：此階段「不需要」回傳 transcript (逐字稿)。
      """;

      final overviewResponseText = await GeminiRestApi.generateContent(
          apiKey, modelName, overviewPrompt, fileUri, 'audio/mp4');
      final overviewJson = _parseJson(overviewResponseText);

      note.title = overviewJson['title'] ?? note.title;
      note.summary = List<String>.from(overviewJson['summary'] ?? []);
      note.tasks = (overviewJson['tasks'] as List<dynamic>?)
              ?.map((e) => TaskItem.fromJson(e))
              .toList() ??
          [];
      note.sections = (overviewJson['sections'] as List<dynamic>?)
              ?.map((e) => Section.fromJson(e))
              .toList() ??
          [];
      double totalDuration =
          (overviewJson['totalDuration'] ?? 600.0).toDouble();

      // 3. 第二階段：分段逐字稿
      List<TranscriptItem> fullTranscript = [];
      int chunkSizeMin = 10;
      int chunkSeconds = chunkSizeMin * 60;
      int totalChunks = (totalDuration / chunkSeconds).ceil();

      for (int i = 0; i < totalChunks; i++) {
        int startSec = i * chunkSeconds;
        int endSec = (i + 1) * chunkSeconds;

        note.summary = [
          "正在生成逐字稿 (${i + 1}/$totalChunks)...",
          ...List<String>.from(overviewJson['summary'] ?? []),
        ];
        await saveNote(note);

        String transcriptPrompt = """
        請針對音訊檔的時間範圍： ${startSec}秒 到 ${endSec}秒。
        提供詳細的「逐字稿」。
        專有詞彙：${vocabList.join(', ')}。
        與會者：${participantList.join(', ')}。
        
        請回傳純 JSON List 格式 (不要 Markdown)：
        [
          {"speaker": "名字", "text": "說話內容", "startTime": 123.5}
        ]
        如果這段時間沒有對話，回傳空陣列 []。
        """;

        try {
          // 使用 REST API 呼叫，重複利用 fileUri
          final chunkResponseText = await GeminiRestApi.generateContent(
              apiKey, modelName, transcriptPrompt, fileUri, 'audio/mp4');

          final List<dynamic> chunkList = _parseJsonList(chunkResponseText);
          final chunkItems =
              chunkList.map((e) => TranscriptItem.fromJson(e)).toList();
          fullTranscript.addAll(chunkItems);
        } catch (e) {
          print("Chunk $i failed: $e");
          fullTranscript.add(TranscriptItem(
              speaker: "System",
              text: "[此段落分析失敗: $e]",
              startTime: startSec.toDouble()));
        }
      }

      note.transcript = fullTranscript;
      note.summary = List<String>.from(overviewJson['summary'] ?? []);
      note.status = NoteStatus.success;
      await saveNote(note);
    } catch (e) {
      print("Analysis Error: $e");
      note.status = NoteStatus.failed;
      note.summary = ["分析失敗: $e"];
      await saveNote(note);
    }
  }

  static Map<String, dynamic> _parseJson(String? text) {
    if (text == null) return {};
    String cleanText = text.trim();
    if (cleanText.startsWith('```json')) {
      cleanText = cleanText.replaceAll('```json', '').replaceAll('```', '');
    } else if (cleanText.startsWith('```')) {
      cleanText = cleanText.replaceAll('```', '');
    }
    try {
      return jsonDecode(cleanText);
    } catch (e) {
      return {};
    }
  }

  static List<dynamic> _parseJsonList(String? text) {
    if (text == null) return [];
    String cleanText = text.trim();
    if (cleanText.startsWith('```json')) {
      cleanText = cleanText.replaceAll('```json', '').replaceAll('```', '');
    } else if (cleanText.startsWith('```')) {
      cleanText = cleanText.replaceAll('```', '');
    }
    try {
      final result = jsonDecode(cleanText);
      if (result is List) return result;
      if (result is Map && result.containsKey('transcript'))
        return result['transcript'];
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
  int _currentIndex = 0;
  final AudioRecorder _audioRecorder = AudioRecorder();
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;
  String _timerText = "00:00";
  int _recordingPart = 1;
  DateTime? _recordingSessionStartTime;

  final List<Widget> _pages = [const HomePage(), const SettingsPage()];

  @override
  void dispose() {
    _timer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  void _toggleRecording() async {
    if (GlobalManager.isRecordingNotifier.value) {
      await _stopAndAnalyze(manualStop: true);
    } else {
      _recordingPart = 1;
      _recordingSessionStartTime = DateTime.now();
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    // 確保權限
    Map<Permission, PermissionStatus> statuses = await [
      Permission.microphone,
    ].request();

    if (statuses[Permission.microphone]!.isGranted) {
      final dir = await getApplicationDocumentsDirectory();
      final fileName =
          "rec_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}_p$_recordingPart.m4a";
      final path = '${dir.path}/$fileName';

      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );

      _stopwatch.reset();
      _stopwatch.start();

      _timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted) return;
        setState(() {
          _timerText =
              "${_stopwatch.elapsed.inMinutes.toString().padLeft(2, '0')}:${(_stopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}";
        });

        final duration = _stopwatch.elapsed;
        final amplitude = await _audioRecorder.getAmplitude();
        final currentAmp = amplitude.current;

        if ((duration.inMinutes >= 29 && currentAmp < -30) ||
            duration.inMinutes >= 30) {
          await _handleAutoSplit();
        }
      });

      GlobalManager.isRecordingNotifier.value = true;
    } else {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("需要麥克風權限才能錄音")));
    }
  }

  Future<void> _handleAutoSplit() async {
    _timer?.cancel();
    final path = await _audioRecorder.stop();
    _stopwatch.stop();

    if (path != null) {
      String title = "會議錄音 Part $_recordingPart";
      if (_recordingSessionStartTime != null) {
        title +=
            " (${DateFormat('HH:mm').format(_recordingSessionStartTime!)})";
      }
      _createNewNoteAndAnalyze(path, title, date: DateTime.now());
    }

    _recordingPart++;
    await _startRecording();
  }

  Future<void> _stopAndAnalyze({bool manualStop = false}) async {
    _timer?.cancel();
    final path = await _audioRecorder.stop();
    _stopwatch.stop();
    GlobalManager.isRecordingNotifier.value = false;

    if (path != null) {
      String title = manualStop && _recordingPart == 1
          ? "會議錄音"
          : "會議錄音 Part $_recordingPart";
      _createNewNoteAndAnalyze(path, title, date: DateTime.now());
    }
    setState(() {
      _timerText = "00:00";
    });
  }

  void _createNewNoteAndAnalyze(
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

  Future<void> _pickFile() async {
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

        _createNewNoteAndAnalyze(file.path, "匯入錄音", date: fileDate);
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

  Future<void> _importYoutube() async {
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
      final tempNote = MeetingNote(
        id: noteId,
        title: "下載中...",
        date: DateTime.now(),
        summary: ["正在下載 YouTube 音訊..."],
        tasks: [],
        transcript: [],
        sections: [],
        audioPath: "",
        status: NoteStatus.downloading,
      );
      await GlobalManager.saveNote(tempNote);
      if (mounted) setState(() {});

      try {
        var yt = YoutubeExplode();
        var video = await yt.videos.get(url);
        tempNote.title = "YT: ${video.title}";
        await GlobalManager.saveNote(tempNote);

        var manifest = await yt.videos.streamsClient.getManifest(url);
        var audioStreamInfo = manifest.audioOnly.withHighestBitrate();
        var stream = yt.videos.streamsClient.get(audioStreamInfo);

        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/$noteId.mp4';
        var file = File(path);
        var fileStream = file.openWrite();
        await stream.pipe(fileStream);
        await fileStream.flush();
        await fileStream.close();
        yt.close();

        tempNote.audioPath = path;
        tempNote.status = NoteStatus.processing;
        tempNote.summary = ["AI 分析中..."];
        await GlobalManager.saveNote(tempNote);
        GlobalManager.analyzeNote(tempNote);
      } catch (e) {
        print("YouTube Download Error: $e");
        tempNote.status = NoteStatus.failed;
        tempNote.summary = ["下載失敗: $e\n(請檢查網路連線或更新 App)"];
        await GlobalManager.saveNote(tempNote);
      }
      if (mounted) setState(() {});
    }
  }

  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.mic, color: Colors.blue),
            title: const Text("開始錄音"),
            onTap: () {
              Navigator.pop(ctx);
              _toggleRecording();
            },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file, color: Colors.orange),
            title: const Text("上傳音訊檔"),
            onTap: () {
              Navigator.pop(ctx);
              _pickFile();
            },
          ),
          ListTile(
            leading: const Icon(Icons.video_library, color: Colors.red),
            title: const Text("輸入 YouTube 連結"),
            onTap: () {
              Navigator.pop(ctx);
              _importYoutube();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(index: _currentIndex, children: _pages),
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
                          "錄音中... $_timerText",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          "Part $_recordingPart",
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.stop_circle, color: Colors.white),
                      onPressed: _toggleRecording,
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
                  color: _currentIndex == 0 ? Colors.blue : Colors.grey,
                ),
                onPressed: () => setState(() => _currentIndex = 0),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: GlobalManager.isRecordingNotifier,
                builder: (context, isRecording, child) {
                  return FloatingActionButton(
                    onPressed: isRecording ? _toggleRecording : _showAddMenu,
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
                  color: _currentIndex == 1 ? Colors.blue : Colors.grey,
                ),
                onPressed: () => setState(() => _currentIndex = 1),
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
  List<MeetingNote> _notes = [];

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(existingJson);
        setState(() {
          _notes = jsonList.map((e) => MeetingNote.fromJson(e)).toList();
          _notes.sort((a, b) {
            if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
            return b.date.compareTo(a.date);
          });
        });
      } catch (e) {
        print("Load error: $e");
      }
    }
  }

  Future<void> _togglePin(MeetingNote note) async {
    note.isPinned = !note.isPinned;
    await GlobalManager.saveNote(note);
    _loadNotes();
  }

  Future<void> _deleteNote(String id) async {
    await GlobalManager.deleteNote(id);
    _loadNotes();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("會議記錄列表"), centerTitle: true),
      body: RefreshIndicator(
        onRefresh: _loadNotes,
        child: _notes.isEmpty
            ? const Center(child: Text("尚無紀錄，點擊下方 + 開始"))
            : ListView.builder(
                itemCount: _notes.length,
                itemBuilder: (context, index) {
                  final note = _notes[index];
                  return Dismissible(
                    key: Key(note.id),
                    background: Container(
                      color: Colors.red,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    direction: DismissDirection.endToStart,
                    onDismissed: (direction) => _deleteNote(note.id),
                    child: Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: note.status == NoteStatus.success
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
                        subtitle: Text(
                          DateFormat('yyyy/MM/dd HH:mm').format(note.date),
                        ),
                        trailing: IconButton(
                          icon: Icon(
                            note.isPinned
                                ? Icons.push_pin
                                : Icons.push_pin_outlined,
                            color: note.isPinned ? Colors.blue : Colors.grey,
                          ),
                          onPressed: () => _togglePin(note),
                        ),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => NoteDetailPage(note: note),
                            ),
                          );
                          _loadNotes();
                        },
                      ),
                    ),
                  );
                },
              ),
      ),
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
      if (mounted) setState(() => _position = p);
    });
  }

  Future<void> _reloadNote() async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    if (existingJson != null) {
      final List<dynamic> jsonList = jsonDecode(existingJson);
      final updatedNoteJson = jsonList.firstWhere(
        (e) => e['id'] == _note.id,
        orElse: () => null,
      );
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
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _playPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play(DeviceFileSource(_note.audioPath));
    }
  }

  void _seekTo(double seconds) {
    _audioPlayer.seek(Duration(seconds: seconds.toInt()));
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
            onPressed: () => Navigator.pop(context),
            child: const Text("取消"),
          ),
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
        title: const Text("重新分析"),
        content: const Text("確定要重新執行 AI 分析嗎？這將會覆蓋目前的分析結果。"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _note.status = NoteStatus.processing;
                _note.summary = ["AI 分析中..."];
              });
              GlobalManager.analyzeNote(_note);
            },
            child: const Text("確定", style: TextStyle(color: Colors.red)),
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
                decoration: const InputDecoration(labelText: "新名稱"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("取消"),
          ),
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
                  if (item.speaker == oldName) {
                    item.speaker = newName;
                  }
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
    TextEditingController controller = TextEditingController(
      text: _note.transcript[index].text,
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("編輯逐字稿"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              maxLines: 5,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: "修改內容...",
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "💡 提示：在上方框選文字後，點擊右側按鈕即可加入字典。",
                    style: TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.bookmark_add, color: Colors.orange),
                  tooltip: "將框選文字加入字典",
                  onPressed: () {
                    if (controller.selection.isValid &&
                        !controller.selection.isCollapsed) {
                      String selectedText = controller.selection.textInside(
                        controller.text,
                      );
                      GlobalManager.addVocab(selectedText);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("已將「$selectedText」加入字典")),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("請先在文字框中選取要加入的詞彙")),
                      );
                    }
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                _note.transcript[index].text = controller.text;
              });
              _saveNoteUpdate();
              Navigator.pop(context);
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
      await file.writeAsString(content);
      await Share.shareXFiles([
        XFile(file.path),
      ], text: '會議記錄匯出: ${_note.title}');
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("匯出失敗: $e")));
    }
  }

  Future<void> _exportCsv() async {
    StringBuffer csv = StringBuffer();
    csv.write('\uFEFF');
    csv.writeln("時間,說話者,內容");
    for (var item in _note.transcript) {
      String time = DateFormat(
        'HH:mm:ss',
      ).format(DateTime(0).add(Duration(seconds: item.startTime.toInt())));
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
    for (var s in _note.summary) md.writeln("- $s");
    md.writeln("");

    md.writeln("## ✅ 待辦事項");
    md.writeln("| 任務 | 負責人 | 期限 |");
    md.writeln("|---|---|---|");
    for (var t in _note.tasks)
      md.writeln("| ${t.description} | ${t.assignee} | ${t.dueDate} |");
    md.writeln("");

    md.writeln("## 💬 逐字稿");
    for (var item in _note.transcript) {
      String time = DateFormat(
        'mm:ss',
      ).format(DateTime(0).add(Duration(seconds: item.startTime.toInt())));
      md.writeln("**$time [${item.speaker}]**: ${item.text}\n");
    }
    await _exportFile('md', md.toString());
  }

  Future<void> _generatePdf() async {
    final pdf = pw.Document();
    final font = await PdfGoogleFonts.notoSansTCRegular();
    pdf.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(base: font),
        build: (context) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              _note.title,
              style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
            ),
          ),
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
                      DateFormat('mm:ss').format(
                        DateTime(0).add(Duration(seconds: t.startTime.toInt())),
                      ),
                      style: const pw.TextStyle(color: PdfColors.grey),
                    ),
                  ),
                  pw.SizedBox(
                    width: 60,
                    child: pw.Text(
                      t.speaker,
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                  pw.Expanded(child: pw.Text(t.text)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    await Printing.sharePdf(
      bytes: await pdf.save(),
      filename: 'meeting_note.pdf',
    );
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
                child: Text(_note.title, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.edit, size: 16, color: Colors.white54),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "重新分析",
            onPressed: _reAnalyze,
          ),
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
                child: Text("刪除紀錄", style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.grey[200],
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 40,
                        color: Colors.blue,
                      ),
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
                      "${_position.inMinutes}:${(_position.inSeconds % 60).toString().padLeft(2, '0')} / ${_duration.inMinutes}:${(_duration.inSeconds % 60).toString().padLeft(2, '0')}",
                    ),
                  ],
                ),
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
              Tab(text: "段落回顧"),
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
                        Text("AI 正在努力分析中..."),
                      ],
                    ),
                  )
                : _note.status == NoteStatus.failed
                    ? Center(
                        child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text("分析失敗: ${_note.summary.firstOrNull}",
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.red)),
                      ))
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildSummaryTab(),
                          _buildTranscriptTab(),
                          _buildSectionTab(),
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
          const Text(
            "📝 重點摘要",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ..._note.summary.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("• ", style: TextStyle(fontSize: 16)),
                  Expanded(
                    child: Text(s, style: const TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 32),
          const Text(
            "✅ 待辦事項",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
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

  Widget _buildTranscriptTab() {
    return ListView.builder(
      itemCount: _note.transcript.length,
      itemBuilder: (context, index) {
        final item = _note.transcript[index];
        return ListTile(
          leading: InkWell(
            onTap: () => _changeSpeaker(index),
            child: CircleAvatar(
              child: Text(item.speaker.isNotEmpty ? item.speaker[0] : "?"),
            ),
          ),
          title: Text(
            item.speaker,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: Colors.blueGrey,
            ),
          ),
          subtitle: Text(item.text, style: const TextStyle(fontSize: 16)),
          trailing: Text(
            DateFormat('mm:ss').format(
              DateTime(0).add(Duration(seconds: item.startTime.toInt())),
            ),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          onTap: () => _seekTo(item.startTime),
          onLongPress: () => _editTranscriptItem(index),
        );
      },
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
            title: Text(
              section.title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              "${(section.endTime - section.startTime).toInt()} 秒",
            ),
            leading: const Icon(Icons.bookmark),
            onTap: () => _seekTo(section.startTime),
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
  final List<String> _models = [
    'gemini-flash-latest', // 保留您指定的
    'gemini-1.5-flash-latest', // 官方建議的
    'gemini-2.5-flash',
    'gemini-1.5-flash',
    'gemini-pro-latest',
    'gemini-2.5-pro',
    'gemini-1.5-pro',
    'gemini-1.0-pro',
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text = prefs.getString('api_key') ?? '';
      _selectedModel = prefs.getString('model_name') ?? 'gemini-flash-latest';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text);
    await prefs.setString('model_name', _selectedModel);

    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("設定已儲存")));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("設定")),
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
          DropdownButtonFormField<String>(
            value: _selectedModel,
            items: _models
                .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                .toList(),
            onChanged: (val) => setState(() => _selectedModel = val!),
            decoration: const InputDecoration(labelText: "選擇 AI 模型"),
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

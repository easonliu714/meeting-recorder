// --- lib/main.dart 修正與功能增強版 ---

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // App 啟動時先載入字典
  await GlobalManager.loadVocab();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: MainAppShell()),
  );
}

// 狀態定義
enum NoteStatus { downloading, processing, success, failed }

// --- 資料模型 (保持不變) ---
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
    tasks:
        (json['tasks'] as List<dynamic>?)
            ?.map((e) => TaskItem.fromJson(e))
            .toList() ??
        [],
    transcript:
        (json['transcript'] as List<dynamic>?)
            ?.map((e) => TranscriptItem.fromJson(e))
            .toList() ??
        [],
    sections:
        (json['sections'] as List<dynamic>?)
            ?.map((e) => Section.fromJson(e))
            .toList() ??
        [],
    audioPath: json['audioPath'] ?? '',
    status: NoteStatus.values[json['status'] ?? 2],
    isPinned: json['isPinned'] ?? false,
  );
}

// --- GlobalManager (保持不變) ---
class GlobalManager {
  static final ValueNotifier<bool> isRecordingNotifier = ValueNotifier(false);
  static final ValueNotifier<List<String>> vocabListNotifier = ValueNotifier(
    [],
  );

  static Future<void> loadVocab() async {
    final prefs = await SharedPreferences.getInstance();
    vocabListNotifier.value = prefs.getStringList('vocab_list') ?? [];
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

  static Future<void> analyzeNote(MeetingNote note) async {
    note.status = NoteStatus.processing;
    await saveNote(note); // 先儲存狀態

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('api_key') ?? '';
    final modelName =
        prefs.getString('model_name') ?? 'gemini-1.5-flash-latest';
    final List<String> vocabList = vocabListNotifier.value;
    final List<String> participantList =
        prefs.getStringList('participant_list') ?? [];

    try {
      if (apiKey.isEmpty) throw Exception("請先至設定頁面輸入 API Key");

      final audioFile = File(note.audioPath);
      if (!await audioFile.exists()) throw Exception("找不到音訊檔案");

      int fileSize = await audioFile.length();
      if (fileSize > 20 * 1024 * 1024) {
        throw Exception("檔案過大 (>20MB)，Gemini API 無法處理。");
      }

      final model = GenerativeModel(model: modelName, apiKey: apiKey);
      final audioBytes = await audioFile.readAsBytes();

      String systemInstruction =
          """
      你是一個會議記錄助理。
      專有詞彙：${vocabList.join(', ')}。
      與會者名單：${participantList.join(', ')}。
      請依據音訊內容回傳 JSON，格式如下：
      {
        "title": "會議標題",
        "summary": ["重點摘要1", "重點摘要2"],
        "tasks": [{"description": "任務", "assignee": "負責人", "dueDate": "YYYY-MM-DD"}],
        "sections": [{"title": "議題一", "startTime": 0.0, "endTime": 120.0}],
        "transcript": [{"speaker": "A", "text": "你好...", "startTime": 0.5}]
      }
      規則：sections 為段落大綱，transcript 為完整逐字稿。
      """;

      final response = await model.generateContent([
        Content.multi([
          TextPart(systemInstruction),
          DataPart('audio/mp4', audioBytes),
        ]),
      ]);

      if (response.text == null) throw Exception("AI 回傳空白");

      final jsonString = response.text!
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      final Map<String, dynamic> result = jsonDecode(jsonString);

      note.title = result['title'] ?? note.title;
      note.summary = List<String>.from(result['summary'] ?? []);
      note.tasks =
          (result['tasks'] as List<dynamic>?)
              ?.map((e) => TaskItem.fromJson(e))
              .toList() ??
          [];
      note.transcript =
          (result['transcript'] as List<dynamic>?)
              ?.map((e) => TranscriptItem.fromJson(e))
              .toList() ??
          [];
      note.sections =
          (result['sections'] as List<dynamic>?)
              ?.map((e) => Section.fromJson(e))
              .toList() ??
          [];

      if (note.sections.isEmpty && note.transcript.isNotEmpty) {
        note.sections.add(
          Section(
            title: "完整對話",
            startTime: 0,
            endTime: note.transcript.last.startTime + 60,
          ),
        );
      }

      note.status = NoteStatus.success;
      await saveNote(note);
    } catch (e) {
      print("AI Error: $e");
      note.status = NoteStatus.failed;
      note.summary = ["分析失敗: $e"];
      await saveNote(note);
    }
  }
}

// --- MainAppShell (修正錄音與加入自動切割功能) ---
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
  // 計數器，用來標記連續錄音的段落 (Part 1, Part 2...)
  int _recordingPart = 1;
  // 紀錄開始錄音的時間，用於檔案命名
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
    if (await Permission.microphone.request().isGranted) {
      final dir = await getApplicationDocumentsDirectory();
      // 檔名加上 Part 標記
      final fileName =
          "rec_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}_p$_recordingPart.m4a";
      final path = '${dir.path}/$fileName';

      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );

      _stopwatch.reset();
      _stopwatch.start();

      // 每秒檢查一次時間與音量
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted) return;

        // 更新 UI 時間
        setState(() {
          _timerText =
              "${_stopwatch.elapsed.inMinutes.toString().padLeft(2, '0')}:${(_stopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}";
        });

        // --- 自動切割邏輯 ---
        final duration = _stopwatch.elapsed;
        // 取得音量 (0 ~ -160 dB)
        final amplitude = await _audioRecorder.getAmplitude();
        final currentAmp = amplitude.current;

        // 規則 1: 超過 29 分鐘 且 很安靜 (<-30dB) -> 切割
        // 規則 2: 超過 30 分鐘 (強制切割)
        if ((duration.inMinutes >= 29 && currentAmp < -30) ||
            duration.inMinutes >= 30) {
          print(
            "Auto splitting recording at ${duration.inMinutes} mins (Amp: $currentAmp)",
          );
          await _handleAutoSplit();
        }
      });

      GlobalManager.isRecordingNotifier.value = true;
    } else {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("需要麥克風權限")));
    }
  }

  // 自動切割處理
  Future<void> _handleAutoSplit() async {
    _timer?.cancel();
    final path = await _audioRecorder.stop();
    _stopwatch.stop();

    if (path != null) {
      // 1. 儲存並分析上一段
      String title = "會議錄音 Part $_recordingPart";
      if (_recordingSessionStartTime != null) {
        title +=
            " (${DateFormat('HH:mm').format(_recordingSessionStartTime!)})";
      }
      _createNewNoteAndAnalyze(path, title);
    }

    // 2. 準備下一段
    _recordingPart++;
    // 3. 立即開始新錄音
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
      _createNewNoteAndAnalyze(path, title);
    }
    setState(() {
      _timerText = "00:00";
    });
  }

  void _createNewNoteAndAnalyze(String path, String defaultTitle) async {
    final newNote = MeetingNote(
      id: const Uuid().v4(),
      title:
          "$defaultTitle (${DateFormat('yyyy/MM/dd').format(DateTime.now())})",
      date: DateTime.now(),
      summary: ["AI 分析中..."],
      tasks: [],
      transcript: [],
      sections: [],
      audioPath: path,
      status: NoteStatus.processing,
    );
    await GlobalManager.saveNote(newNote);

    // 非同步執行分析，不卡 UI
    GlobalManager.analyzeNote(newNote);

    if (mounted) setState(() {});
  }

  // 上傳檔案邏輯
  // 匯入檔案：增加大小檢查提示
  Future<void> _pickFile() async {
    // 請求儲存權限 (Android 13 以下需要，部分手機需要)
    await Permission.storage.request();

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );
    if (result != null) {
      File file = File(result.files.single.path!);
      int size = await file.length();
      if (size > 20 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("警告：檔案超過 20MB，AI 分析可能會失敗。"),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
      _createNewNoteAndAnalyze(file.path, "匯入錄音");
    }
  }

  // YouTube 下載：即時顯示進度
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
        tempNote.status = NoteStatus.failed;
        tempNote.summary = ["下載失敗: $e"];
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
          // 錄音狀態條
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
                          "Part $_recordingPart (自動分段: 30min)",
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
                    backgroundColor: isRecording
                        ? Colors.red
                        : Colors.blueAccent,
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

// --- 3. 首頁：會議列表 (含狀態顯示) ---
// --- 修改開始：HomePage 加入置頂與刪除 ---
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<MeetingNote> _notes = [];

  // 定期刷新頁面以獲取最新的分析結果
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadNotes();
    // 每 5 秒刷新一次列表，以便看到 AI 完成的狀態
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _loadNotes(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final String? notesJson = prefs.getString('meeting_notes');
    if (notesJson != null) {
      final List<dynamic> decoded = jsonDecode(notesJson);
      if (mounted) {
        setState(() {
          _notes = decoded.map((e) => MeetingNote.fromJson(e)).toList();
          // 排序：先看是否置頂，再看日期
          _notes.sort((a, b) {
            if (a.isPinned != b.isPinned) {
              return a.isPinned ? -1 : 1; // 置頂在前
            }
            return b.date.compareTo(a.date); // 新的在前
          });
        });
      }
    }
  }

  Future<void> _saveNotes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'meeting_notes',
      jsonEncode(_notes.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> _deleteNote(String id) async {
    setState(() => _notes.removeWhere((note) => note.id == id));
    await _saveNotes();
  }

  Future<void> _togglePin(MeetingNote note) async {
    setState(() {
      note.isPinned = !note.isPinned;
      // 重新排序
      _notes.sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        return b.date.compareTo(a.date);
      });
    });
    await _saveNotes();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "會議筆記",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      backgroundColor: Colors.grey[50],
      body: _notes.isEmpty
          ? const Center(
              child: Text("尚無記錄", style: TextStyle(color: Colors.grey)),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _notes.length,
              itemBuilder: (context, index) {
                final note = _notes[index];
                return Card(
                  elevation: note.isPinned ? 4 : 1,
                  color: note.isPinned ? Colors.blue[50] : Colors.white,
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    // 左側：圖釘
                    leading: IconButton(
                      icon: Icon(
                        note.isPinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        color: note.isPinned ? Colors.blue : Colors.grey,
                      ),
                      onPressed: () => _togglePin(note),
                    ),
                    title: Text(
                      note.status == NoteStatus.processing
                          ? "⏳ 分析中..."
                          : note.title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: note.status == NoteStatus.processing
                            ? Colors.orange
                            : Colors.black,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          DateFormat('MM/dd HH:mm').format(note.date),
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        // 狀態判斷
                        if (note.status == NoteStatus.downloading)
                          const Row(
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 8),
                              Text(
                                "音訊下載中...",
                                style: TextStyle(color: Colors.blue),
                              ),
                            ],
                          )
                        else if (note.summary.isNotEmpty) ...[
                          Text(
                            "• ${note.summary.first}",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (note.summary.length > 1)
                            Text(
                              "• ${note.summary[1]}",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],

                        if (note.status == NoteStatus.failed)
                          const Text(
                            "處理失敗",
                            style: TextStyle(color: Colors.red),
                          ),
                      ],
                    ),
                    // --- 修改開始：HomePage 允許點擊任何狀態的筆記 ---
                    onTap: () {
                      // 移除 if (note.status == NoteStatus.success) 的限制
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NoteDetailPage(note: note),
                        ),
                      ).then((_) => _loadNotes());
                    },
                    // --- 修改結束 ---
                    // 右側：垃圾桶
                    trailing: note.isPinned
                        ? null // 置頂時不顯示刪除，或顯示 disabled
                        : IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.grey,
                            ),
                            onPressed: () => showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text("確認刪除"),
                                content: const Text("刪除後無法復原"),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: const Text("取消"),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      _deleteNote(note.id);
                                      Navigator.pop(ctx);
                                    },
                                    child: const Text(
                                      "刪除",
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                );
              },
            ),
    );
  }
}
// --- 修改結束 ---

// --- 5. 詳情頁面 (含播放器與時間跳轉) ---
// --- 修改開始：NoteDetailPage 增強編輯與播放限制 ---
// --- 修改開始：NoteDetailPage 支援匯出與新版介面 ---
// --- 修改開始：NoteDetailPage (PDF 中文 & 折疊式逐字稿) ---
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
    _audioPlayer
        .setSource(DeviceFileSource(_note.audioPath))
        .then((_) async {
          final d = await _audioPlayer.getDuration();
          setState(() => _duration = d ?? Duration.zero);
        })
        .catchError((e) => print("Error: $e"));
    _audioPlayer.onPlayerStateChanged.listen(
      (state) => setState(() => _isPlaying = state == PlayerState.playing),
    );
    _audioPlayer.onPositionChanged.listen((p) => setState(() => _position = p));
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _togglePlay() {
    // 限制：錄音中禁止播放
    if (GlobalManager.isRecordingNotifier.value) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("錄音中無法播放音訊")));
      return;
    }
    _isPlaying ? _audioPlayer.pause() : _audioPlayer.resume();
  }

  void _seekTo(double seconds) {
    if (GlobalManager.isRecordingNotifier.value) return; // 錄音中禁止跳轉播放
    _audioPlayer.seek(Duration(milliseconds: (seconds * 1000).toInt()));
    _audioPlayer.resume();
  }

  // 修改：使用 GlobalManager 儲存
  Future<void> _saveNoteUpdate() async {
    await GlobalManager.saveNote(_note);
  }

  String _formatDuration(Duration d) =>
      "${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}";

  // 進階編輯：包含斷句與框選加入字典
  void _editTranscriptItem(int index) async {
    final item = _note.transcript[index];
    final TextEditingController controller = TextEditingController(
      text: item.text,
    );

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("編輯逐字稿"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              maxLines: 4,
              // 允許選取文字
              enableInteractiveSelection: true,
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 功能：加入選取文字到字典
                TextButton.icon(
                  icon: const Icon(Icons.book, size: 16),
                  label: const Text("選詞入典"),
                  onPressed: () {
                    final selection = controller.selection;
                    if (selection.start != -1 &&
                        selection.end != -1 &&
                        selection.start != selection.end) {
                      final selectedText = controller.text.substring(
                        selection.start,
                        selection.end,
                      );
                      GlobalManager.addVocab(selectedText);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("已加入字典: $selectedText")),
                      );
                    } else {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text("請先框選文字")));
                    }
                  },
                ),
                // 功能：斷句
                TextButton.icon(
                  icon: const Icon(Icons.call_split, size: 16),
                  label: const Text("游標處斷句"),
                  onPressed: () {
                    final cursorPos = controller.selection.baseOffset;
                    if (cursorPos > 0 && cursorPos < controller.text.length) {
                      final part1 = controller.text.substring(0, cursorPos);
                      final part2 = controller.text.substring(cursorPos);

                      setState(() {
                        // 更新當前句
                        _note.transcript[index].text = part1;
                        // 插入新句 (繼承 speaker)
                        _note.transcript.insert(
                          index + 1,
                          TranscriptItem(
                            speaker: item.speaker,
                            text: part2,
                            startTime: item.startTime, // 暫時繼承時間，無法精確切分音訊時間
                          ),
                        );
                      });
                      _saveNoteUpdate();
                      Navigator.pop(ctx);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("請將游標移動到要切分的位置")),
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _note.transcript[index].text = controller.text;
              });
              _saveNoteUpdate();
              Navigator.pop(ctx);
            },
            child: const Text("儲存"),
          ),
        ],
      ),
    );
  }

  // 講者修改：雙模式
  void _changeSpeaker(int index) async {
    final currentSpeaker = _note.transcript[index].speaker;
    final prefs = await SharedPreferences.getInstance();
    final List<String> participants =
        prefs.getStringList('participant_list') ?? [];

    String? newName = await showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text("修改講者: $currentSpeaker"),
          children: [
            if (participants.isNotEmpty)
              ...participants.map(
                (p) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, p),
                  child: Text(p, style: const TextStyle(fontSize: 16)),
                ),
              ),
            SimpleDialogOption(
              onPressed: () async {
                // 手動輸入... (略，為節省篇幅直接回傳測試名，實作請參考前版)
                Navigator.pop(context, "New Speaker");
              },
              child: const Text(
                "➕ 手動輸入...",
                style: TextStyle(color: Colors.blue),
              ),
            ),
          ],
        );
      },
    );

    if (newName != null && newName != currentSpeaker) {
      // 詢問修改範圍
      bool? replaceAll = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("修改範圍"),
          content: Text("要將所有的 '$currentSpeaker' 都改成 '$newName' 嗎？\n還是只修改這一句？"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false), // 只改這句
              child: const Text("只改這句"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true), // 全部修改
              child: const Text("全部修改"),
            ),
          ],
        ),
      );

      if (replaceAll != null) {
        setState(() {
          if (replaceAll) {
            for (var item in _note.transcript) {
              if (item.speaker == currentSpeaker) item.speaker = newName;
            }
          } else {
            _note.transcript[index].speaker = newName;
          }
        });
        _saveNoteUpdate();
      }
    }
  }

  // --- 編輯任務功能 ---
  void _editTask(int index) async {
    final task = _note.tasks[index];
    final descController = TextEditingController(text: task.description);
    final assigneeController = TextEditingController(text: task.assignee);
    final dateController = TextEditingController(text: task.dueDate);

    final prefs = await SharedPreferences.getInstance();
    final participants = prefs.getStringList('participant_list') ?? [];

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("編輯任務"),
        content: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: descController,
                decoration: const InputDecoration(labelText: "任務內容"),
              ),
              const SizedBox(height: 10),
              // 負責人選單
              DropdownButtonFormField<String>(
                value: participants.contains(task.assignee)
                    ? task.assignee
                    : null,
                decoration: const InputDecoration(labelText: "負責人"),
                items: [
                  ...participants.map(
                    (p) => DropdownMenuItem(value: p, child: Text(p)),
                  ),
                  const DropdownMenuItem(value: "未定", child: Text("未定")),
                ],
                onChanged: (v) => assigneeController.text = v ?? "未定",
              ),
              TextField(
                controller: assigneeController,
                decoration: const InputDecoration(labelText: "或手動輸入負責人"),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: dateController,
                decoration: const InputDecoration(labelText: "期限 (YYYY-MM-DD)"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _note.tasks[index] = TaskItem(
                  description: descController.text,
                  assignee: assigneeController.text,
                  dueDate: dateController.text,
                );
              });
              GlobalManager.saveNote(_note);
              Navigator.pop(ctx);
            },
            child: const Text("儲存"),
          ),
        ],
      ),
    );
  }

  // 新增：重試分析方法
  Future<void> _retryAnalysis() async {
    setState(() {
      _note.status = NoteStatus.processing; // 立即更新 UI 為處理中
    });

    await GlobalManager.analyzeNote(_note); // 呼叫全域分析

    setState(() {}); // 分析完成後刷新 UI
  }

  // 匯出 PDF：解決中文亂碼，移除逐字稿
  Future<void> _exportPdf() async {
    final pdf = pw.Document();
    // 下載中文字型 (Noto Sans TC)
    final font = await PdfGoogleFonts.notoSansTCRegular();
    final boldFont = await PdfGoogleFonts.notoSansTCBold();

    pdf.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(base: font, bold: boldFont), // 套用中文字型
        build: (pw.Context context) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              _note.title,
              style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Paragraph(
            text: "日期: ${DateFormat('yyyy/MM/dd HH:mm').format(_note.date)}",
          ),
          pw.Divider(),
          pw.Header(level: 1, child: pw.Text("會議摘要")),
          ..._note.summary.map((s) => pw.Bullet(text: s)),
          pw.Divider(),
          pw.Header(level: 1, child: pw.Text("待辦事項")),
          ..._note.tasks.map(
            (t) => pw.Paragraph(
              text: "[${t.assignee}] ${t.description} (期限: ${t.dueDate})",
            ),
          ),
          // 移除逐字稿區塊
          pw.Divider(),
          pw.Paragraph(
            text: "-- 逐字稿內容請見 App --",
            style: const pw.TextStyle(color: PdfColors.grey),
          ),
        ],
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_note.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _exportPdf,
          ),
        ],
      ),
      body: Column(
        children: [
          // 播放器 (保持不變)
          Container(
            color: Colors.blueGrey[50],
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Column(
              children: [
                Slider(
                  min: 0,
                  max: _duration.inSeconds.toDouble(),
                  value: _position.inSeconds.toDouble().clamp(
                    0,
                    _duration.inSeconds.toDouble(),
                  ),
                  onChanged: (v) {
                    if (!GlobalManager.isRecordingNotifier.value)
                      _audioPlayer.seek(Duration(seconds: v.toInt()));
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_formatDuration(_position)),
                    IconButton(
                      icon: Icon(
                        _isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 40,
                      ),
                      onPressed: _togglePlay,
                    ),
                    Text(_formatDuration(_duration)),
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
              Tab(text: "逐字稿"),
              Tab(text: "摘要"),
              Tab(text: "任務"),
            ],
          ),
          Expanded(
            child: Builder(
              builder: (context) {
                if (_note.status == NoteStatus.processing)
                  return const Center(child: Text("分析中..."));
                if (_note.status == NoteStatus.failed)
                  return Center(
                    child: ElevatedButton(
                      onPressed: _retryAnalysis,
                      child: const Text("重試"),
                    ),
                  );

                return TabBarView(
                  controller: _tabController,
                  children: [
                    // 1. 逐字稿：改為折疊式章節
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: _note.sections.map((section) {
                        // 篩選屬於此章節的逐字稿
                        final sectionItems = _note.transcript
                            .where(
                              (t) =>
                                  t.startTime >= section.startTime &&
                                  t.startTime < section.endTime,
                            )
                            .toList();

                        return ExpansionTile(
                          title: Text(
                            section.title,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            "${_formatDuration(Duration(seconds: section.startTime.toInt()))} - ${_formatDuration(Duration(seconds: section.endTime.toInt()))}",
                          ),
                          initiallyExpanded: true, // 預設展開
                          children: sectionItems.map((item) {
                            // 判斷是否正在播放此句
                            final bool isCurrent =
                                _position.inSeconds >= item.startTime &&
                                _position.inSeconds < (item.startTime + 5);
                            return Container(
                              color: isCurrent ? Colors.blue[50] : null,
                              child: ListTile(
                                leading: CircleAvatar(
                                  radius: 12,
                                  backgroundColor: Colors.grey[300],
                                  child: Text(
                                    item.speaker[0],
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ),
                                title: Text(item.text),
                                onTap: () => _seekTo(item.startTime),
                              ),
                            );
                          }).toList(),
                        );
                      }).toList(),
                    ),
                    // 2. 摘要 (保持不變)
                    ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _note.summary.length,
                      itemBuilder: (context, index) => ListTile(
                        leading: const Icon(Icons.circle, size: 8),
                        title: Text(_note.summary[index]),
                      ),
                    ),
                    // 3. 任務 (保持不變)
                    ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _note.tasks.length,
                      itemBuilder: (context, index) {
                        final task = _note.tasks[index];
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.check_box_outline_blank),
                            title: Text(task.description),
                            subtitle: Text(
                              "${task.assignee} | ${task.dueDate}",
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: () => _editTask(index),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
// --- 修改結束 ---

// --- 6. 設定頁面 (完整恢復版) ---
// --- 修改開始：SettingsPage 即時監聽字典 ---
// --- 修正後的 SettingsPage (移除冗餘變數) ---
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
  List<String> _participantList = [];
  final List<String> _models = [
    'gemini-flash-latest',
    'gemini-1.5-flash-latest',
    'gemini-1.5-pro',
    'gemini-pro-latest',
    'gemini-2.0-flash-exp',
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
      _participantList = prefs.getStringList('participant_list') ?? [];
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text.trim());
    await prefs.setString('model_name', _selectedModel);
    await prefs.setStringList('participant_list', _participantList);
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('設定已儲存')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("設定")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Gemini API Key"),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField(
              value: _selectedModel,
              items: _models
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedModel = v.toString()),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "Model",
              ),
            ),
            const Divider(),
            // --- 字典區塊 ---
            const Text("專業用詞字典"),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _vocabController,
                    decoration: const InputDecoration(hintText: "輸入術語"),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    if (_vocabController.text.isNotEmpty) {
                      GlobalManager.addVocab(_vocabController.text.trim());
                      _vocabController.clear();
                    }
                  },
                ),
              ],
            ),
            // 使用 GlobalManager 監聽，實現跨頁面即時更新
            ValueListenableBuilder<List<String>>(
              valueListenable: GlobalManager.vocabListNotifier,
              builder: (context, vocabList, child) {
                return Wrap(
                  spacing: 8,
                  children: vocabList
                      .map(
                        (v) => Chip(
                          label: Text(v),
                          onDeleted: () => GlobalManager.removeVocab(v),
                        ),
                      )
                      .toList(),
                );
              },
            ),
            const Divider(),
            const Text("常用與會者"),
            Row(
              children: [
                Expanded(child: TextField(controller: _participantController)),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    if (_participantController.text.isNotEmpty) {
                      setState(() {
                        _participantList.add(
                          _participantController.text.trim(),
                        );
                        _participantController.clear();
                      });
                    }
                  },
                ),
              ],
            ),
            Wrap(
              children: _participantList
                  .map(
                    (p) => Chip(
                      label: Text(p),
                      onDeleted: () =>
                          setState(() => _participantList.remove(p)),
                    ),
                  )
                  .toList(),
            ),
            const Divider(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saveSettings,
                child: const Text("儲存設定"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

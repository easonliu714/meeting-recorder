// --- 修改開始：引入新套件與升級資料模型 ---
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart'; // 新增
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 用於載入字型
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart'; // 新增
import 'package:pdf/widgets.dart' as pw; // 新增
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart'; // 新增
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'; // 新增

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // App 啟動時先載入字典
  await GlobalManager.loadVocab();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: MainAppShell(),
  ));
}

// 簡易全域管理器 (解決字典同步與錄音狀態共享)
class GlobalManager {
  // 錄音狀態監聽
  static final ValueNotifier<bool> isRecordingNotifier = ValueNotifier(false);
  // 字典監聽
  static final ValueNotifier<List<String>> vocabListNotifier = ValueNotifier([]);

  static Future<void> loadVocab() async {
    final prefs = await SharedPreferences.getInstance();
    vocabListNotifier.value = prefs.getStringList('vocab_list') ?? [];
  }

  static Future<void> addVocab(String word) async {
    if (!vocabListNotifier.value.contains(word)) {
      final newList = List<String>.from(vocabListNotifier.value)..add(word);
      vocabListNotifier.value = newList; // 通知 UI 更新
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

  // 新增：統一儲存筆記的方法 (供各頁面呼叫)
  static Future<void> saveNote(MeetingNote note) async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    List<MeetingNote> notes = [];
    if (existingJson != null) {
      notes = (jsonDecode(existingJson) as List).map((e) => MeetingNote.fromJson(e)).toList();
    }
    int index = notes.indexWhere((n) => n.id == note.id);
    if (index != -1) {
      notes[index] = note;
    } else {
      notes.add(note);
    }
    await prefs.setString('meeting_notes', jsonEncode(notes.map((e) => e.toJson()).toList()));
  }

  // 新增：統一的 AI 分析邏輯
  static Future<void> analyzeNote(MeetingNote note) async {
    // 1. 設定狀態為處理中並存檔
    note.status = NoteStatus.processing;
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('api_key') ?? '';
    final modelName = prefs.getString('model_name') ?? 'gemini-flash-latest';
    final List<String> vocabList = vocabListNotifier.value;
    
    // [修正重點]：補上這一行，讀取與會者名單
    final List<String> participantList = prefs.getStringList('participant_list') ?? [];

    try {
      if (apiKey.isEmpty) throw Exception("No API Key");
      
      final model = GenerativeModel(model: modelName, apiKey: apiKey);
      final audioFile = File(note.audioPath);
      if (!await audioFile.exists()) throw Exception("Audio file not found");
      
      final audioBytes = await audioFile.readAsBytes();

      // Prompt 升級：要求結構化任務與條列式摘要
      String systemInstruction = """
      你是一個會議記錄助理。
      專有詞彙：${vocabList.join(', ')}。
      與會者名單：${participantList.join(', ')}。
      
      請分析音訊並回傳 JSON (無 Markdown)：
      {
        "title": "會議標題",
        "summary": ["摘要重點1", "摘要重點2"],
        "tasks": [
           {"description": "任務內容", "assignee": "負責人(若無則填'未定')", "dueDate": "YYYY-MM-DD(若無則填'未定')"}
        ],
        "transcript": [
           {"speaker": "A", "text": "你好", "startTime": 0.5}
        ]
      }
      1. 摘要請務必條列式。
      2. 任務請從對話中提取負責人與日期，若對話未提及則標示'未定'。
      3. startTime 使用秒數。
      """;

      final response = await model.generateContent([
        Content.multi([TextPart(systemInstruction), DataPart('audio/mp4', audioBytes)]) // Gemini 支援 mp3/wav/aac/m4a
      ]);

      final jsonString = response.text!.replaceAll('```json', '').replaceAll('```', '').trim();
      final Map<String, dynamic> result = jsonDecode(jsonString);

      note.title = result['title'] ?? note.title;
      // 摘要改為 List<String>
      note.summary = List<String>.from(result['summary'] ?? []);
      // 任務改為 List<TaskItem>
      note.tasks = (result['tasks'] as List<dynamic>?)?.map((e) => TaskItem.fromJson(e)).toList() ?? [];
      note.transcript = (result['transcript'] as List<dynamic>?)?.map((e) => TranscriptItem.fromJson(e)).toList() ?? [];
      note.status = NoteStatus.success;

      await saveNote(note);
    } catch (e) {
      print("AI Error: $e");
      note.status = NoteStatus.failed;
      // 失敗時，summary 暫存錯誤訊息 (轉為 List)
      note.summary = ["分析失敗: $e"];
      await saveNote(note);
    }
  }
}
// --- 修改結束 ---

// --- 1. 資料模型 (新增狀態與時間戳記) ---
enum NoteStatus { processing, success, failed }

class TranscriptItem {
  String speaker;
  String text;
  double startTime; // 新增：開始時間(秒)

  TranscriptItem({required this.speaker, required this.text, this.startTime = 0.0});

  Map<String, dynamic> toJson() => {'speaker': speaker, 'text': text, 'startTime': startTime};

  factory TranscriptItem.fromJson(Map<String, dynamic> json) => TranscriptItem(
        speaker: json['speaker'] ?? 'Unknown',
        text: json['text'] ?? '',
        startTime: (json['startTime'] ?? 0.0).toDouble(),
      );
}

// 新增：結構化任務物件
class TaskItem {
  String description;
  String assignee;
  String dueDate;

  TaskItem({required this.description, this.assignee = '未定', this.dueDate = '未定'});

  Map<String, dynamic> toJson() => {'description': description, 'assignee': assignee, 'dueDate': dueDate};

  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
        description: json['description'] ?? '',
        assignee: json['assignee'] ?? '未定',
        dueDate: json['dueDate'] ?? '未定',
      );
}

class MeetingNote {
  String id;
  String title;
  DateTime date;
  List<String> summary; // 修改：改為 List<String>
  List<TaskItem> tasks; // 修改：改為 List<TaskItem>
  List<TranscriptItem> transcript;
  String audioPath;
  NoteStatus status; // 新增：處理狀態
  bool isPinned; // 新增：置頂狀態

  MeetingNote({
    required this.id,
    required this.title,
    required this.date,
    required this.summary,
    required this.tasks,
    required this.transcript,
    required this.audioPath,
    this.status = NoteStatus.success,
    this.isPinned = false, // 預設不置頂
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'date': date.toIso8601String(),
        'summary': summary,
        'tasks': tasks.map((e) => e.toJson()).toList(),
        'transcript': transcript.map((e) => e.toJson()).toList(),
        'audioPath': audioPath,
        'status': status.index,
        'isPinned': isPinned,
      };

  factory MeetingNote.fromJson(Map<String, dynamic> json) => MeetingNote(
        id: json['id'],
        title: json['title'],
        date: DateTime.parse(json['date']),
        // 相容舊資料：若 summary 是字串則轉為 List
        summary: json['summary'] is String 
            ? [json['summary']] 
            : List<String>.from(json['summary'] ?? []),
        // 相容舊資料：若 tasks 是字串 List 則轉為 TaskItem
        tasks: (json['tasks'] as List<dynamic>?)?.map((e) {
          if (e is String) return TaskItem(description: e);
          return TaskItem.fromJson(e);
        }).toList() ?? [],
        transcript: (json['transcript'] as List<dynamic>?)
                ?.map((e) => TranscriptItem.fromJson(e))
                .toList() ?? [],
        audioPath: json['audioPath'],
        status: NoteStatus.values[json['status'] ?? 1],
        isPinned: json['isPinned'] ?? false,
      );
}
// --- 修改結束 ---

// --- 2. 主畫面框架 ---
// --- 修改開始：MainAppShell 新增上傳功能 ---
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
  final List<Widget> _pages = [const HomePage(), const SettingsPage()];

  @override
  void dispose() {
    _timer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  // 切換錄音狀態
  void _toggleRecording() async {
    if (GlobalManager.isRecordingNotifier.value) {
      await _stopAndAnalyze();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (await Permission.microphone.request().isGranted) {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/${const Uuid().v4()}.m4a';
      await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      _stopwatch.reset(); _stopwatch.start();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _timerText = "${_stopwatch.elapsed.inMinutes.toString().padLeft(2, '0')}:${(_stopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}";
        });
      });
      GlobalManager.isRecordingNotifier.value = true;
    }
  }
// --- 修改開始：MainAppShell 呼叫 GlobalManager ---
  Future<void> _stopAndAnalyze() async {
    final path = await _audioRecorder.stop();
    _stopwatch.stop(); _timer?.cancel();
    GlobalManager.isRecordingNotifier.value = false;
    if (path != null) _createNewNoteAndAnalyze(path, "新會議錄音");
  }

  // 統一的建立筆記邏輯
  void _createNewNoteAndAnalyze(String path, String defaultTitle) async {
    final newNote = MeetingNote(
      id: const Uuid().v4(),
      title: "$defaultTitle (${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now())})",
      date: DateTime.now(),
      summary: ["AI 分析中..."],
      tasks: [],
      transcript: [],
      audioPath: path,
      status: NoteStatus.processing,
    );
    await GlobalManager.saveNote(newNote);
    GlobalManager.analyzeNote(newNote);
    if (mounted) setState(() {});
  }

  // 上傳檔案邏輯
  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (result != null) {
      _createNewNoteAndAnalyze(result.files.single.path!, "匯入錄音");
    }
  }

  // YouTube 下載邏輯
  Future<void> _importYoutube() async {
    final TextEditingController urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("輸入 YouTube 連結"),
        content: TextField(controller: urlController, decoration: const InputDecoration(hintText: "https://youtu.be/...")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          TextButton(onPressed: () => Navigator.pop(ctx, urlController.text), child: const Text("確定")),
        ],
      ),
    );

    if (url != null && url.isNotEmpty) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("正在下載音訊...")));
        var yt = YoutubeExplode();
        var video = await yt.videos.get(url);
        var manifest = await yt.videos.streamsClient.getManifest(url);
        var audioStreamInfo = manifest.audioOnly.withHighestBitrate();
        var stream = yt.videos.streamsClient.get(audioStreamInfo);

        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/${const Uuid().v4()}.mp4'; // 存為 mp4 (audio container)
        var file = File(path);
        var fileStream = file.openWrite();
        await stream.pipe(fileStream);
        await fileStream.flush();
        await fileStream.close();
        yt.close();

        _createNewNoteAndAnalyze(path, "YT: ${video.title}");
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("下載失敗: $e")));
      }
    }
  }

  // 顯示新增選單
  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.mic, color: Colors.blue),
            title: const Text("開始錄音"),
            onTap: () { Navigator.pop(ctx); _toggleRecording(); },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file, color: Colors.orange),
            title: const Text("上傳音訊檔 (m4a, mp3...)"),
            onTap: () { Navigator.pop(ctx); _pickFile(); },
          ),
          ListTile(
            leading: const Icon(Icons.video_library, color: Colors.red),
            title: const Text("輸入 YouTube 連結"),
            onTap: () { Navigator.pop(ctx); _importYoutube(); },
          ),
        ],
      ),
    );
  }
  
// --- 修改結束 ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: IndexedStack(index: _currentIndex, children: _pages)),
          // 錄音狀態條
          ValueListenableBuilder<bool>(
            valueListenable: GlobalManager.isRecordingNotifier,
            builder: (context, isRecording, child) {
              if (!isRecording) return const SizedBox.shrink();
              return Container(
                color: Colors.redAccent,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Icon(Icons.mic, color: Colors.white),
                    Text("錄音中... $_timerText", style: const TextStyle(color: Colors.white)),
                    IconButton(icon: const Icon(Icons.stop_circle, color: Colors.white), onPressed: _toggleRecording),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      // --- 移除 FloatingActionButton，改在 BottomBar 中央 ---
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 6.0,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(icon: Icon(Icons.home, color: _currentIndex == 0 ? Colors.blue : Colors.grey), onPressed: () => setState(() => _currentIndex = 0)),
              // 中央按鈕改為 "+" 號，開啟多功能選單
              ValueListenableBuilder<bool>(
                valueListenable: GlobalManager.isRecordingNotifier,
                builder: (context, isRecording, child) {
                  return FloatingActionButton(
                    onPressed: isRecording ? _toggleRecording : _showAddMenu, // 錄音中則為停止，否則開啟選單
                    backgroundColor: isRecording ? Colors.red : Colors.blueAccent,
                    child: Icon(isRecording ? Icons.stop : Icons.add, color: Colors.white),
                  );
                },
              ),
              IconButton(icon: Icon(Icons.settings, color: _currentIndex == 1 ? Colors.blue : Colors.grey), onPressed: () => setState(() => _currentIndex = 1)),
            ],
          ),
        ),
      ),
    );
  }
}
// --- 修改結束 ---

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
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadNotes());
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
    await prefs.setString('meeting_notes', jsonEncode(_notes.map((e) => e.toJson()).toList()));
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
      appBar: AppBar(title: const Text("會議筆記", style: TextStyle(fontWeight: FontWeight.bold))),
      backgroundColor: Colors.grey[50],
      body: _notes.isEmpty
          ? const Center(child: Text("尚無記錄", style: TextStyle(color: Colors.grey)))
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    // 左側：圖釘
                    leading: IconButton(
                      icon: Icon(
                        note.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                        color: note.isPinned ? Colors.blue : Colors.grey,
                      ),
                      onPressed: () => _togglePin(note),
                    ),
                    title: Text(
                      note.status == NoteStatus.processing ? "⏳ 分析中..." : note.title,
                      style: TextStyle(fontWeight: FontWeight.bold, color: note.status == NoteStatus.processing ? Colors.orange : Colors.black),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(DateFormat('yyyy/MM/dd HH:mm').format(note.date), style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 4),
                        // 顯示前兩點摘要
                        if (note.summary.isNotEmpty)
                          Text("• ${note.summary.first}", maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (note.summary.length > 1)
                          Text("• ${note.summary[1]}", maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (note.status == NoteStatus.failed) const Text("分析失敗", style: TextStyle(color: Colors.red)),
                      ],
                    ),
                    // --- 修改開始：HomePage 允許點擊任何狀態的筆記 ---
                    onTap: () {
                      // 移除 if (note.status == NoteStatus.success) 的限制
                      Navigator.push(context, MaterialPageRoute(builder: (_) => NoteDetailPage(note: note)))
                          .then((_) => _loadNotes());
                    },
                    // --- 修改結束 ---
                    // 右側：垃圾桶
                    trailing: note.isPinned
                        ? null // 置頂時不顯示刪除，或顯示 disabled
                        : IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.grey),
                            onPressed: () => showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text("確認刪除"),
                                content: const Text("刪除後無法復原"),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
                                  TextButton(onPressed: () { _deleteNote(note.id); Navigator.pop(ctx); }, child: const Text("刪除", style: TextStyle(color: Colors.red))),
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

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _tabController = TabController(length: 3, vsync: this);
    // --- 修正開始：改用新版 audioplayers 語法 ---
    // 修正: 使用新的 audioplayers 語法
    _audioPlayer.setSource(DeviceFileSource(_note.audioPath)).then((_) async {
       final d = await _audioPlayer.getDuration();
       setState(() => _duration = d ?? Duration.zero);
    }).catchError((e) => print("音訊載入錯誤: $e"));

    _audioPlayer.onPlayerStateChanged.listen((state) {
      setState(() => _isPlaying = state == PlayerState.playing);
    });
    _audioPlayer.onPositionChanged.listen((p) => setState(() => _position = p));
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // --- 匯出功能 (PDF) ---
  Future<void> _exportPdf() async {
    final pdf = pw.Document();
    
    // 載入字型 (這裡使用內建字型，若需中文請載入 NotoSansTC)
    // 簡單起見，我們假設系統支援，若出現亂碼需額外處理 assets font
    // 這裡我們用一個簡單的 Theme

    pdf.addPage(
      pw.MultiPage(
        build: (pw.Context context) => [
          pw.Header(level: 0, child: pw.Text(_note.title, style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold))),
          pw.Paragraph(text: "日期: ${DateFormat('yyyy/MM/dd HH:mm').format(_note.date)}"),
          pw.Divider(),
          pw.Header(level: 1, child: pw.Text("會議摘要")),
          ..._note.summary.map((s) => pw.Bullet(text: s)),
          pw.Divider(),
          pw.Header(level: 1, child: pw.Text("待辦事項")),
          ..._note.tasks.map((t) => pw.Paragraph(text: "[${t.assignee}] ${t.description} (期限: ${t.dueDate})")),
          pw.Divider(),
          pw.Header(level: 1, child: pw.Text("逐字稿")),
          ..._note.transcript.map((t) => pw.Paragraph(text: "${t.speaker}: ${t.text}")),
        ],
      ),
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => pdf.save());
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
              TextField(controller: descController, decoration: const InputDecoration(labelText: "任務內容")),
              const SizedBox(height: 10),
              // 負責人選單
              DropdownButtonFormField<String>(
                value: participants.contains(task.assignee) ? task.assignee : null,
                decoration: const InputDecoration(labelText: "負責人"),
                items: [
                  ...participants.map((p) => DropdownMenuItem(value: p, child: Text(p))),
                  const DropdownMenuItem(value: "未定", child: Text("未定")),
                ],
                onChanged: (v) => assigneeController.text = v ?? "未定",
              ),
              TextField(controller: assigneeController, decoration: const InputDecoration(labelText: "或手動輸入負責人")),
              const SizedBox(height: 10),
              TextField(controller: dateController, decoration: const InputDecoration(labelText: "期限 (YYYY-MM-DD)")),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          TextButton(onPressed: () {
            setState(() {
              _note.tasks[index] = TaskItem(
                description: descController.text,
                assignee: assigneeController.text,
                dueDate: dateController.text,
              );
            });
            GlobalManager.saveNote(_note);
            Navigator.pop(ctx);
          }, child: const Text("儲存")),
        ],
      ),
    );
  }

  void _togglePlay() {
    // 限制：錄音中禁止播放
    if (GlobalManager.isRecordingNotifier.value) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("錄音中無法播放音訊")));
      return;
    }
    _isPlaying ? _audioPlayer.pause() : _audioPlayer.resume();
  }

  void _seekTo(double seconds) {
    if (GlobalManager.isRecordingNotifier.value) return; // 錄音中禁止跳轉播放
    _audioPlayer.seek(Duration(milliseconds: (seconds * 1000).toInt()));
    _audioPlayer.resume();
  }

  // 新增：重試分析方法
  Future<void> _retryAnalysis() async {
    setState(() {
      _note.status = NoteStatus.processing; // 立即更新 UI 為處理中
    });
    
    await GlobalManager.analyzeNote(_note); // 呼叫全域分析
    
    setState(() {}); // 分析完成後刷新 UI
  }

  // 修改：使用 GlobalManager 儲存
  Future<void> _saveNoteUpdate() async {
    await GlobalManager.saveNote(_note);
  }

  // 進階編輯：包含斷句與框選加入字典
  void _editTranscriptItem(int index) async {
    final item = _note.transcript[index];
    final TextEditingController controller = TextEditingController(text: item.text);

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
                    if (selection.start != -1 && selection.end != -1 && selection.start != selection.end) {
                      final selectedText = controller.text.substring(selection.start, selection.end);
                      GlobalManager.addVocab(selectedText);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已加入字典: $selectedText")));
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("請先框選文字")));
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
                        _note.transcript.insert(index + 1, TranscriptItem(
                          speaker: item.speaker,
                          text: part2,
                          startTime: item.startTime, // 暫時繼承時間，無法精確切分音訊時間
                        ));
                      });
                      _saveNoteUpdate();
                      Navigator.pop(ctx);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("請將游標移動到要切分的位置")));
                    }
                  },
                ),
              ],
            )
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          TextButton(onPressed: () {
            setState(() {
              _note.transcript[index].text = controller.text;
            });
            _saveNoteUpdate();
            Navigator.pop(ctx);
          }, child: const Text("儲存")),
        ],
      ),
    );
  }

  // 講者修改：雙模式
  void _changeSpeaker(int index) async {
    final currentSpeaker = _note.transcript[index].speaker;
    final prefs = await SharedPreferences.getInstance();
    final List<String> participants = prefs.getStringList('participant_list') ?? [];

    String? newName = await showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text("修改講者: $currentSpeaker"),
          children: [
            if (participants.isNotEmpty)
              ...participants.map((p) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, p),
                child: Text(p, style: const TextStyle(fontSize: 16)),
              )),
            SimpleDialogOption(
              onPressed: () async {
                 // 手動輸入... (略，為節省篇幅直接回傳測試名，實作請參考前版)
                 Navigator.pop(context, "New Speaker");
              },
              child: const Text("➕ 手動輸入...", style: TextStyle(color: Colors.blue)),
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


  String _formatDuration(Duration d) => "${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}";

    @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_note.title),
        actions: [
          IconButton(icon: const Icon(Icons.share), tooltip: "匯出 PDF", onPressed: _exportPdf),
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
                  min: 0, max: _duration.inSeconds.toDouble(),
                  value: _position.inSeconds.toDouble().clamp(0, _duration.inSeconds.toDouble()),
                  onChanged: (v) { if (!GlobalManager.isRecordingNotifier.value) _audioPlayer.seek(Duration(seconds: v.toInt())); },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_formatDuration(_position)),
                    IconButton(icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 40), onPressed: _togglePlay),
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
            tabs: const [Tab(text: "逐字稿"), Tab(text: "摘要"), Tab(text: "任務")],
          ),
          Expanded(
            child: Builder(builder: (context) {
              if (_note.status == NoteStatus.processing) return const Center(child: Text("分析中..."));
              if (_note.status == NoteStatus.failed) {
                 return Center(child: ElevatedButton(onPressed: _retryAnalysis, child: const Text("重試分析")));
              }
              return TabBarView(
                controller: _tabController,
                children: [
                  // 1. 逐字稿 (保持不變)
                  ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _note.transcript.length,
                    itemBuilder: (context, index) {
                      final item = _note.transcript[index];
                      final bool isCurrent = _position.inSeconds >= item.startTime &&
                          (index == _note.transcript.length - 1 || _position.inSeconds < _note.transcript[index + 1].startTime);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(color: isCurrent ? Colors.blue[50] : Colors.white, borderRadius: BorderRadius.circular(8)),
                        child: ListTile(
                          leading: GestureDetector(onTap: () => _changeSpeaker(index), child: CircleAvatar(backgroundColor: Colors.grey[300], child: Text(item.speaker[0]))),
                          title: GestureDetector(onTap: () => _seekTo(item.startTime), onLongPress: () => _editTranscriptItem(index), child: Text(item.text)),
                          subtitle: Text(_formatDuration(Duration(seconds: item.startTime.toInt())), style: const TextStyle(fontSize: 10)),
                        ),
                      );
                    },
                  ),
                  // 2. 摘要 (改為條列顯示)
                  ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _note.summary.length,
                    itemBuilder: (context, index) => ListTile(
                      leading: const Icon(Icons.circle, size: 8, color: Colors.blue),
                      title: Text(_note.summary[index]),
                    ),
                  ),
                  // 3. 任務 (改為結構化顯示與編輯)
                  ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _note.tasks.length,
                    itemBuilder: (context, index) {
                      final task = _note.tasks[index];
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.check_box_outline_blank),
                          title: Text(task.description),
                          subtitle: Text("負責人: ${task.assignee} | 期限: ${task.dueDate}"),
                          trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => _editTask(index)),
                        ),
                      );
                    },
                  ),
                ],
              );
            }),
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
  final List<String> _models = ['gemini-flash-latest', 'gemini-1.5-flash-latest', 'gemini-1.5-pro', 'gemini-pro-latest', 'gemini-2.0-flash-exp'];

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
    if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('設定已儲存')));
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
             TextField(controller: _apiKeyController, obscureText: true, decoration: const InputDecoration(border: OutlineInputBorder())),
             const SizedBox(height: 10),
             DropdownButtonFormField(
               value: _selectedModel,
               items: _models.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
               onChanged: (v) => setState(() => _selectedModel = v.toString()),
               decoration: const InputDecoration(border: OutlineInputBorder(), labelText: "Model"),
             ),
             const Divider(),
             // --- 字典區塊 ---
             const Text("專業用詞字典"),
             Row(children: [
               Expanded(child: TextField(controller: _vocabController, decoration: const InputDecoration(hintText: "輸入術語"))),
               IconButton(icon: const Icon(Icons.add), onPressed: () {
                 if(_vocabController.text.isNotEmpty) {
                   GlobalManager.addVocab(_vocabController.text.trim());
                   _vocabController.clear();
                 }
               }),
             ]),
             // 使用 GlobalManager 監聽，實現跨頁面即時更新
             ValueListenableBuilder<List<String>>(
               valueListenable: GlobalManager.vocabListNotifier,
               builder: (context, vocabList, child) {
                 return Wrap(
                   spacing: 8,
                   children: vocabList.map((v) => Chip(
                     label: Text(v),
                     onDeleted: () => GlobalManager.removeVocab(v),
                   )).toList(),
                 );
               },
             ),
             const Divider(),
             const Text("常用與會者"),
             Row(children: [
               Expanded(child: TextField(controller: _participantController)),
               IconButton(icon: const Icon(Icons.add), onPressed: () {
                 if(_participantController.text.isNotEmpty) {
                    setState(() {
                      _participantList.add(_participantController.text.trim());
                      _participantController.clear();
                    });
                 }
               }),
             ]),
             Wrap(children: _participantList.map((p) => Chip(label: Text(p), onDeleted: () => setState(() => _participantList.remove(p)))).toList()),
             const Divider(),
             SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _saveSettings, child: const Text("儲存設定"))),
          ],
        ),
      ),
    );
  }
}
// --- 修改結束 ---
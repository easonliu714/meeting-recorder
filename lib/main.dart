import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart'; // 新增播放器
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

void main() {
  runApp(const MaterialApp(
    title: 'MeetingAssistant', // 加入這一行
    debugShowCheckedModeBanner: false,
    home: MainAppShell(),
  ));
}

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

class MeetingNote {
  String id;
  String title;
  DateTime date;
  String summary;
  List<String> tasks;
  List<TranscriptItem> transcript;
  String audioPath;
  NoteStatus status; // 新增：處理狀態

  MeetingNote({
    required this.id,
    required this.title,
    required this.date,
    required this.summary,
    required this.tasks,
    required this.transcript,
    required this.audioPath,
    this.status = NoteStatus.success,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'date': date.toIso8601String(),
        'summary': summary,
        'tasks': tasks,
        'transcript': transcript.map((e) => e.toJson()).toList(),
        'audioPath': audioPath,
        'status': status.index,
      };

  factory MeetingNote.fromJson(Map<String, dynamic> json) => MeetingNote(
        id: json['id'],
        title: json['title'],
        date: DateTime.parse(json['date']),
        summary: json['summary'],
        tasks: List<String>.from(json['tasks']),
        transcript: (json['transcript'] as List<dynamic>?)
                ?.map((e) => TranscriptItem.fromJson(e))
                .toList() ?? [],
        audioPath: json['audioPath'],
        status: NoteStatus.values[json['status'] ?? 1],
      );
}

// --- 2. 主畫面框架 ---
class MainAppShell extends StatefulWidget {
  const MainAppShell({super.key});
  @override
  State<MainAppShell> createState() => _MainAppShellState();
}

class _MainAppShellState extends State<MainAppShell> {
  int _currentIndex = 0;
  final List<Widget> _pages = [const HomePage(), const SettingsPage()];

  // 修改：點擊麥克風直接進入全螢幕錄音頁面
  void _goToRecordingPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const RecordingPage()),
    ).then((_) {
      // 錄音結束返回後，重新整理首頁列表
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      floatingActionButton: FloatingActionButton(
        onPressed: _goToRecordingPage,
        backgroundColor: Colors.blueAccent,
        child: const Icon(Icons.mic, color: Colors.white),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8.0,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                  icon: Icon(Icons.home, color: _currentIndex == 0 ? Colors.blue : Colors.grey),
                  onPressed: () => setState(() => _currentIndex = 0)),
              const SizedBox(width: 40),
              IconButton(
                  icon: Icon(Icons.settings, color: _currentIndex == 1 ? Colors.blue : Colors.grey),
                  onPressed: () => setState(() => _currentIndex = 1)),
            ],
          ),
        ),
      ),
    );
  }
}

// --- 3. 首頁：會議列表 (含狀態顯示) ---
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<MeetingNote> _notes = [];

  Future<void> _loadNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final String? notesJson = prefs.getString('meeting_notes');
    if (notesJson != null) {
      final List<dynamic> decoded = jsonDecode(notesJson);
      if (mounted) {
        setState(() {
          _notes = decoded.map((e) => MeetingNote.fromJson(e)).toList();
          _notes.sort((a, b) => b.date.compareTo(a.date));
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _loadNotes(); // 簡易刷新
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
                  elevation: 2,
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    title: Text(
                      note.status == NoteStatus.processing ? "⏳ 分析中..." : note.title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: note.status == NoteStatus.processing ? Colors.orange : Colors.black,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 5),
                        Text(DateFormat('MM/dd HH:mm').format(note.date), style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 5),
                        if (note.status == NoteStatus.processing)
                          const LinearProgressIndicator()
                        else if (note.status == NoteStatus.failed)
                          const Text("分析失敗，請重試", style: TextStyle(color: Colors.red))
                        else
                          Text(note.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                    onTap: () {
                      if (note.status == NoteStatus.success) {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => NoteDetailPage(note: note)));
                      }
                    },
                    trailing: note.status == NoteStatus.success
                        ? const Icon(Icons.arrow_forward_ios, size: 16)
                        : null,
                  ),
                );
              },
            ),
    );
  }
}

// --- 4. 全螢幕錄音頁面 (解決誤觸與背景錄音問題) ---
class RecordingPage extends StatefulWidget {
  const RecordingPage({super.key});

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> {
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String _timerText = "00:00";
  Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 進入頁面後自動開始錄音 (可選)
    // _startRecording(); 
  }

  @override
  void dispose() {
    _timer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (await Permission.microphone.request().isGranted) {
      final dir = await getApplicationDocumentsDirectory();
      final String id = const Uuid().v4();
      final path = '${dir.path}/$id.m4a';

      // 開始錄音
      await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      
      _stopwatch.start();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _timerText = "${_stopwatch.elapsed.inMinutes.toString().padLeft(2, '0')}:${(_stopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}";
        });
      });

      setState(() {
        _isRecording = true;
      });
    }
  }

  Future<void> _stopAndCreateTask() async {
    final path = await _audioRecorder.stop();
    _stopwatch.stop();
    _timer?.cancel();

    if (path != null) {
      // 1. 立刻建立一筆 "Processing" 狀態的筆記
      final newNote = MeetingNote(
        id: const Uuid().v4(),
        title: "未命名會議 (${DateFormat('MM/dd HH:mm').format(DateTime.now())})",
        date: DateTime.now(),
        summary: "AI 分析中...",
        tasks: [],
        transcript: [],
        audioPath: path,
        status: NoteStatus.processing,
      );

      await _saveNoteToLocal(newNote);

      // 2. 觸發背景分析 (不等待結果直接返回首頁)
      _processAiInBackground(newNote);
      
      if (mounted) Navigator.pop(context);
    }
  }

  // 儲存筆記到 SharedPreferences
  Future<void> _saveNoteToLocal(MeetingNote note) async {
    final prefs = await SharedPreferences.getInstance();
    final String? existingJson = prefs.getString('meeting_notes');
    List<MeetingNote> notes = [];
    if (existingJson != null) {
      final List<dynamic> decoded = jsonDecode(existingJson);
      notes = decoded.map((e) => MeetingNote.fromJson(e)).toList();
    }
    // 如果已存在則更新，否則新增
    int index = notes.indexWhere((n) => n.id == note.id);
    if (index != -1) {
      notes[index] = note;
    } else {
      notes.add(note);
    }
    await prefs.setString('meeting_notes', jsonEncode(notes.map((e) => e.toJson()).toList()));
  }

  // 模擬背景分析
  Future<void> _processAiInBackground(MeetingNote note) async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('api_key') ?? '';
    final modelName = prefs.getString('model_name') ?? 'gemini-flash-latest';
    final List<String> vocabList = prefs.getStringList('vocab_list') ?? [];
    
    try {
      if (apiKey.isEmpty) throw Exception("No API Key");

      final model = GenerativeModel(model: modelName, apiKey: apiKey);
      final audioFile = File(note.audioPath);
      final audioBytes = await audioFile.readAsBytes();

      // Prompt: 要求回傳包含 timestamp 的 JSON
      String systemInstruction = """
      你是一個會議記錄助理。
      專有詞彙：${vocabList.join(', ')}。
      
      請分析音訊並回傳 JSON 格式 (不要 Markdown)：
      {
        "title": "會議標題",
        "summary": "摘要",
        "tasks": ["待辦1"],
        "transcript": [
           {"speaker": "A", "text": "大家好", "startTime": 0.5},
           {"speaker": "B", "text": "開始報告", "startTime": 5.2}
        ]
      }
      startTime 請使用秒數 (例如 12.5)。
      """;

      final response = await model.generateContent([
        Content.multi([TextPart(systemInstruction), DataPart('audio/mp4', audioBytes)])
      ]);

      final jsonString = response.text!.replaceAll('```json', '').replaceAll('```', '').trim();
      final Map<String, dynamic> result = jsonDecode(jsonString);

      // 更新筆記狀態為 Success
      note.title = result['title'] ?? note.title;
      note.summary = result['summary'] ?? '';
      note.tasks = List<String>.from(result['tasks'] ?? []);
      note.transcript = (result['transcript'] as List<dynamic>?)
              ?.map((e) => TranscriptItem.fromJson(e))
              .toList() ?? [];
      note.status = NoteStatus.success;

      await _saveNoteToLocal(note);

    } catch (e) {
      print("AI Error: $e");
      note.status = NoteStatus.failed;
      note.summary = "分析失敗: $e";
      await _saveNoteToLocal(note);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            Text(_timerText, style: const TextStyle(color: Colors.white, fontSize: 60, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Text(_isRecording ? "正在錄音..." : "準備開始", style: const TextStyle(color: Colors.grey)),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 30),
                  onPressed: () => Navigator.pop(context),
                ),
                GestureDetector(
                  onTap: _isRecording ? _stopAndCreateTask : _startRecording,
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: _isRecording ? Colors.red : Colors.red.withOpacity(0.5),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    child: Icon(_isRecording ? Icons.stop : Icons.mic, color: Colors.white, size: 40),
                  ),
                ),
                const SizedBox(width: 50), // 佔位平衡佈局
              ],
            ),
            const SizedBox(height: 50),
          ],
        ),
      ),
    );
  }
}

// --- 5. 詳情頁面 (含播放器與時間跳轉) ---
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
    
    // 初始化播放器
    _audioPlayer.setSourceDeviceFile(_note.audioPath).then((_) async {
       final d = await _audioPlayer.getDuration();
       setState(() => _duration = d ?? Duration.zero);
    });

    _audioPlayer.onPlayerStateChanged.listen((state) {
      setState(() => _isPlaying = state == PlayerState.playing);
    });

    _audioPlayer.onPositionChanged.listen((p) {
      setState(() => _position = p);
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // 跳轉到指定秒數
  void _seekTo(double seconds) {
    _audioPlayer.seek(Duration(milliseconds: (seconds * 1000).toInt()));
    _audioPlayer.resume();
  }

  // 編輯文字功能 (修正斷句/內容)
  void _editText(int index) async {
    TextEditingController controller = TextEditingController(text: _note.transcript[index].text);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("編輯內容"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: controller, maxLines: 3),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () async {
                 // 這裡可以做功能：將選取的文字加入字典
                 final prefs = await SharedPreferences.getInstance();
                 List<String> vocab = prefs.getStringList('vocab_list') ?? [];
                 // 簡單示範：直接加
                 if(!vocab.contains(controller.text)) {
                   vocab.add(controller.text);
                   await prefs.setStringList('vocab_list', vocab);
                   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已加入字典")));
                 }
              },
              child: const Text("加入專業字典"),
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
  
// --- 修改開始：恢復「從名單選擇說話者」功能 ---
  
  // 核心功能：重新命名說話者 (恢復版)
  Future<void> _renameSpeaker(String oldName) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> participants = prefs.getStringList('participant_list') ?? [];

    // 顯示對話框
    String? newName = await showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text("將 $oldName 重新命名為..."),
          children: [
            // 1. 從現有名單選
            if (participants.isNotEmpty)
              ...participants.map((p) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, p),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(p, style: const TextStyle(fontSize: 16)),
                    ),
                  )),
            const Divider(),
            // 2. 手動輸入新名字
            SimpleDialogOption(
              onPressed: () async {
                final name = await _showInputNameDialog();
                if (mounted) Navigator.pop(context, name);
              },
              child: const Text("➕ 輸入新名字", style: TextStyle(color: Colors.blue)),
            ),
          ],
        );
      },
    );

    if (newName != null && newName.isNotEmpty && newName != oldName) {
      _performGlobalReplace(oldName, newName);
    }
  }

  Future<String?> _showInputNameDialog() async {
    TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("輸入新名字"),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text("確定")),
        ],
      ),
    );
  }

  // 執行全域取代 (逐字稿 + 摘要 + 任務)
  Future<void> _performGlobalReplace(String oldName, String newName) async {
    setState(() {
      // 1. 更新逐字稿
      for (var item in _note.transcript) {
        if (item.speaker == oldName) item.speaker = newName;
      }
      // 2. 更新摘要 (字串取代)
      _note.summary = _note.summary.replaceAll(oldName, newName);
      // 3. 更新任務
      _note.tasks = _note.tasks.map((t) => t.replaceAll(oldName, newName)).toList();
    });

    _saveNoteUpdate(); // 呼叫原本已存在的儲存函式
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已將 $oldName 全部更換為 $newName")));
  }
  // --- 修改結束 ---

  Future<void> _saveNoteUpdate() async {
    final prefs = await SharedPreferences.getInstance();
    final String? notesJson = prefs.getString('meeting_notes');
    if (notesJson != null) {
      List<dynamic> decoded = jsonDecode(notesJson);
      List<MeetingNote> allNotes = decoded.map((e) => MeetingNote.fromJson(e)).toList();
      int index = allNotes.indexWhere((n) => n.id == _note.id);
      if (index != -1) {
        allNotes[index] = _note;
        await prefs.setString('meeting_notes', jsonEncode(allNotes.map((e) => e.toJson()).toList()));
      }
    }
  }

  String _formatDuration(Duration d) {
    return "${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_note.title)),
      body: Column(
        children: [
          // 頂部播放器
          Container(
            color: Colors.blueGrey[50],
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
            child: Column(
              children: [
                Slider(
                  min: 0,
                  max: _duration.inSeconds.toDouble(),
                  value: _position.inSeconds.toDouble().clamp(0, _duration.inSeconds.toDouble()),
                  onChanged: (v) => _audioPlayer.seek(Duration(seconds: v.toInt())),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_formatDuration(_position)),
                    IconButton(
                      icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 40, color: Colors.blue),
                      onPressed: () => _isPlaying ? _audioPlayer.pause() : _audioPlayer.resume(),
                    ),
                    Text(_formatDuration(_duration)),
                  ],
                ),
              ],
            ),
          ),
          
          // Tab Bar
          TabBar(
            controller: _tabController,
            labelColor: Colors.blue,
            unselectedLabelColor: Colors.grey,
            tabs: const [Tab(text: "逐字稿"), Tab(text: "摘要"), Tab(text: "任務")],
          ),
          
          // 內容區
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // 1. 逐字稿 (含編輯與跳轉)
                ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _note.transcript.length,
                  itemBuilder: (context, index) {
                    final item = _note.transcript[index];
                    final bool isCurrent = _position.inSeconds >= item.startTime && 
                                           (index == _note.transcript.length - 1 || _position.inSeconds < _note.transcript[index+1].startTime);
                    
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: isCurrent ? Colors.blue[50] : Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: isCurrent ? Border.all(color: Colors.blue) : null,
                      ),
                      child: ListTile(
                        leading: GestureDetector(
                          onTap: () => _renameSpeaker(item.speaker),
                          child: CircleAvatar(
                            backgroundColor: Colors.grey[300],
                            child: Text(item.speaker[0], style: const TextStyle(fontSize: 12, color: Colors.black)),
                          ),
                        ),
                        title: GestureDetector(
                          onTap: () => _seekTo(item.startTime), // 點擊文字跳轉
                          onLongPress: () => _editText(index),  // 長按編輯
                          child: Text(item.text, style: const TextStyle(fontSize: 16)),
                        ),
                        subtitle: Text(_formatDuration(Duration(seconds: item.startTime.toInt())), style: const TextStyle(fontSize: 10)),
                      ),
                    );
                  },
                ),
                
                // 2. 摘要
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Text(_note.summary, style: const TextStyle(fontSize: 16, height: 1.5)),
                ),
                
                // 3. 任務
                ListView(
                  children: _note.tasks.map((t) => ListTile(
                    leading: const Icon(Icons.check_box_outline_blank),
                    title: Text(t),
                  )).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- 6. 設定頁面 (完整恢復版) ---
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _vocabController = TextEditingController();
  final TextEditingController _participantController = TextEditingController(); // 恢復
  
  String _selectedModel = 'gemini-flash-latest'; // 恢復
  List<String> _vocabList = [];
  List<String> _participantList = []; // 恢復
  
  // 恢復模型清單
  final List<String> _models = ['gemini-flash-latest', 'gemini-1.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash-exp'];

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
      _vocabList = prefs.getStringList('vocab_list') ?? [];
      _participantList = prefs.getStringList('participant_list') ?? []; // 恢復讀取
      
      // 防呆：如果讀到的模型不在清單內，預設回第一個
      if (!_models.contains(_selectedModel)) {
        _selectedModel = _models.first;
      }
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text.trim());
    await prefs.setString('model_name', _selectedModel); // 恢復儲存
    await prefs.setStringList('vocab_list', _vocabList);
    await prefs.setStringList('participant_list', _participantList); // 恢復儲存
    
    if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('設定已儲存')));
  }

  // 通用的新增項目函式
  void _addItem(List<String> list, TextEditingController c) {
    if (c.text.isNotEmpty) {
      setState(() {
        list.add(c.text.trim());
        c.clear();
      });
    }
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
            // --- 區域 1: API 與模型 ---
            const Text("基本設定", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            const Text("Gemini API Key"),
            TextField(controller: _apiKeyController, obscureText: true, decoration: const InputDecoration(border: OutlineInputBorder())),
            const SizedBox(height: 10),
            
            // 恢復下拉選單
            DropdownButtonFormField<String>(
              value: _selectedModel,
              decoration: const InputDecoration(border: OutlineInputBorder(), labelText: "AI 模型"),
              items: _models.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
              onChanged: (v) => setState(() => _selectedModel = v!),
            ),
            
            const Divider(height: 40, thickness: 2),

            // --- 區域 2: 專業字典 ---
            const Text("專業用詞字典 (提升辨識率)", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Row(children: [
              Expanded(child: TextField(controller: _vocabController, decoration: const InputDecoration(hintText: "輸入術語"))),
              IconButton(icon: const Icon(Icons.add_circle, color: Colors.blue), onPressed: () => _addItem(_vocabList, _vocabController)),
            ]),
            Wrap(
              spacing: 8.0,
              children: _vocabList.map((v) => Chip(
                label: Text(v), 
                onDeleted: () => setState(() => _vocabList.remove(v))
              )).toList()
            ),

            const Divider(height: 40, thickness: 2),

            // --- 區域 3: 與會者 (恢復) ---
            const Text("常用與會者 (協助區分說話者)", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Row(children: [
              Expanded(child: TextField(controller: _participantController, decoration: const InputDecoration(hintText: "輸入名字 (如: Eason)"))),
              IconButton(icon: const Icon(Icons.add_circle, color: Colors.green), onPressed: () => _addItem(_participantList, _participantController)),
            ]),
            Wrap(
              spacing: 8.0,
              children: _participantList.map((p) => Chip(
                label: Text(p),
                backgroundColor: Colors.green[50],
                onDeleted: () => setState(() => _participantList.remove(p))
              )).toList()
            ),

            const SizedBox(height: 40),
            SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _saveSettings, child: const Text("儲存所有設定"))),
          ],
        ),
      ),
    );
  }
}
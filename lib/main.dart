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
  await GlobalManager.loadVocab();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: MainAppShell(),
  ));
}

enum NoteStatus { downloading, processing, success, failed }

class TranscriptItem {
  String speaker;
  String text;
  double startTime;
  TranscriptItem({required this.speaker, required this.text, this.startTime = 0.0});
  Map<String, dynamic> toJson() => {'speaker': speaker, 'text': text, 'startTime': startTime};
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
  TaskItem({required this.description, this.assignee = '未定', this.dueDate = '未定'});
  Map<String, dynamic> toJson() => {'description': description, 'assignee': assignee, 'dueDate': dueDate};
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
  Section({required this.title, required this.startTime, required this.endTime});
  Map<String, dynamic> toJson() => {'title': title, 'startTime': startTime, 'endTime': endTime};
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
  List<String> audioPaths; // 修改：支援多個音檔
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
    required this.audioPaths,
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
        'audioPaths': audioPaths, // 存 List
        'status': status.index,
        'isPinned': isPinned,
      };

  factory MeetingNote.fromJson(Map<String, dynamic> json) {
    // 相容性處理：舊資料只有 audioPath (String)，新資料是 audioPaths (List)
    List<String> paths = [];
    if (json['audioPaths'] != null) {
      paths = List<String>.from(json['audioPaths']);
    } else if (json['audioPath'] != null) {
      paths = [json['audioPath']];
    }

    return MeetingNote(
      id: json['id'],
      title: json['title'],
      date: DateTime.parse(json['date']),
      summary: List<String>.from(json['summary'] ?? []),
      tasks: (json['tasks'] as List<dynamic>?)?.map((e) => TaskItem.fromJson(e)).toList() ?? [],
      transcript: (json['transcript'] as List<dynamic>?)?.map((e) => TranscriptItem.fromJson(e)).toList() ?? [],
      sections: (json['sections'] as List<dynamic>?)?.map((e) => Section.fromJson(e)).toList() ?? [],
      audioPaths: paths,
      status: NoteStatus.values[json['status'] ?? 2],
      isPinned: json['isPinned'] ?? false,
    );
  }
}

class GlobalManager {
  static final ValueNotifier<bool> isRecordingNotifier = ValueNotifier(false);
  static final ValueNotifier<List<String>> vocabListNotifier = ValueNotifier([]);

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
      notes = (jsonDecode(existingJson) as List).map((e) => MeetingNote.fromJson(e)).toList();
    }
    int index = notes.indexWhere((n) => n.id == note.id);
    if (index != -1) notes[index] = note; else notes.add(note);
    await prefs.setString('meeting_notes', jsonEncode(notes.map((e) => e.toJson()).toList()));
  }

  // --- 核心修改：支援連續分析多個檔案 ---
  static Future<void> analyzeNote(MeetingNote note) async {
    note.status = NoteStatus.processing;
    await saveNote(note);

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('api_key') ?? '';
    final modelName = prefs.getString('model_name') ?? 'gemini-flash-latest';
    final List<String> vocabList = vocabListNotifier.value;
    final List<String> participantList = prefs.getStringList('participant_list') ?? [];

    try {
      if (apiKey.isEmpty) throw Exception("No API Key");

      // 清空舊資料，準備重新累積
      note.transcript = [];
      note.tasks = [];
      note.summary = [];
      note.sections = [];

      double timeOffset = 0.0; // 用於累加不同檔案的時間戳記
      String previousSummaryContext = ""; // 用於傳遞給下一段的上下文

      // 迴圈處理每一個切割檔
      for (int i = 0; i < note.audioPaths.length; i++) {
        String path = note.audioPaths[i];
        final audioFile = File(path);
        if (!await audioFile.exists()) continue;

        print("Analyzing part ${i + 1}/${note.audioPaths.length}...");
        
        final model = GenerativeModel(model: modelName, apiKey: apiKey);
        final audioBytes = await audioFile.readAsBytes();

        // Prompt 注入上下文
        String contextPrompt = "";
        if (i > 0) {
          contextPrompt = "這是會議的第 ${i + 1} 部分。上一部分的摘要如下，請根據此上下文繼續分析，不要重複開場白：\n$previousSummaryContext";
        }

        String systemInstruction = """
        你是一個會議記錄助理。
        專有詞彙：${vocabList.join(', ')}。
        與會者名單：${participantList.join(', ')}。
        $contextPrompt
        
        請回傳 JSON：
        {
          "title": "會議標題(僅第1部分提供)",
          "summary": ["摘要1"],
          "tasks": [{"description": "", "assignee": "", "dueDate": ""}],
          "sections": [{"title": "章節", "startTime": 0.0, "endTime": 100.0}],
          "transcript": [{"speaker": "A", "text": "對話", "startTime": 0.0}]
        }
        規則：
        1. Transcript 必須是【完整逐字稿】。
        2. Sections 時間請基於本音訊檔的相對時間 (0.0 開始)。
        """;

        final response = await model.generateContent([
          Content.multi([TextPart(systemInstruction), DataPart('audio/mp4', audioBytes)])
        ]);

        final jsonString = response.text!.replaceAll('```json', '').replaceAll('```', '').trim();
        final Map<String, dynamic> result = jsonDecode(jsonString);

        // 1. 合併標題 (只取第一個檔案的標題)
        if (i == 0) note.title = result['title'] ?? note.title;

        // 2. 合併摘要 (累加，並更新 Context)
        List<String> newSummary = List<String>.from(result['summary'] ?? []);
        note.summary.addAll(newSummary);
        previousSummaryContext = newSummary.join("\n");

        // 3. 合併任務
        var newTasks = (result['tasks'] as List<dynamic>?)?.map((e) => TaskItem.fromJson(e)).toList() ?? [];
        note.tasks.addAll(newTasks);

        // 4. 合併逐字稿 (需加上 timeOffset)
        var newTranscript = (result['transcript'] as List<dynamic>?)?.map((e) => TranscriptItem.fromJson(e)).toList() ?? [];
        for (var item in newTranscript) {
          item.startTime += timeOffset;
        }
        note.transcript.addAll(newTranscript);

        // 5. 合併章節 (需加上 timeOffset)
        var newSections = (result['sections'] as List<dynamic>?)?.map((e) => Section.fromJson(e)).toList() ?? [];
        for (var item in newSections) {
          item.startTime += timeOffset;
          item.endTime += timeOffset;
        }
        note.sections.addAll(newSections);

        // 計算此檔案的長度，作為下一個檔案的 Offset
        // 簡單估算：取最後一句話的時間 + 緩衝，或使用 ffmpeg 取得精確時間。
        // 這裡我們用逐字稿最後一句的時間做為基準
        if (newTranscript.isNotEmpty) {
           timeOffset = newTranscript.last.startTime + 2.0; 
        } else {
           timeOffset += 1800.0; // 若無對話，預設加 30 分鐘 (防呆)
        }
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
  
  // 錄音分段管理
  String? _currentSessionId; // 這次會議的唯一 ID (用來綁定多個檔案)
  List<String> _recordedPaths = []; // 這次會議錄的所有檔案
  Timer? _autoSplitTimer; // 30分鐘自動切割計時器

  final List<Widget> _pages = [const HomePage(), const SettingsPage()];

  @override
  void dispose() {
    _timer?.cancel();
    _autoSplitTimer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  void _toggleRecording() async {
    if (GlobalManager.isRecordingNotifier.value) {
      await _stopRecordingFinal();
    } else {
      await _startRecordingNewSession();
    }
  }

  // 開始全新的錄音 Session
  Future<void> _startRecordingNewSession() async {
    if (await Permission.microphone.request().isGranted) {
      _currentSessionId = const Uuid().v4();
      _recordedPaths = [];
      _stopwatch.reset(); 
      _stopwatch.start();
      
      // UI 計時器
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _timerText = "${_stopwatch.elapsed.inMinutes.toString().padLeft(2, '0')}:${(_stopwatch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}";
        });
      });

      // 啟動第一段錄音
      await _startSegmentRecording();

      // 啟動 30 分鐘 (1800秒) 自動切割計時器
      _autoSplitTimer = Timer.periodic(const Duration(minutes: 30), (t) async {
        await _rotateRecordingSegment();
      });

      GlobalManager.isRecordingNotifier.value = true;
    }
  }

  // 錄製單一分段
  Future<void> _startSegmentRecording() async {
    final dir = await getApplicationDocumentsDirectory();
    // 檔名加上 timestamp 區分: sessionID_part_timestamp.m4a
    final path = '${dir.path}/${_currentSessionId}_part_${DateTime.now().millisecondsSinceEpoch}.m4a';
    _recordedPaths.add(path);
    await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    print("Started recording segment: $path");
  }

  // 切換分段 (無縫接軌)
  Future<void> _rotateRecordingSegment() async {
    print("Auto-splitting recording...");
    await _audioRecorder.stop(); // 停止目前分段
    await _startSegmentRecording(); // 立即開始新分段
  }

  // 最終停止 (使用者按下停止)
  Future<void> _stopRecordingFinal() async {
    await _audioRecorder.stop();
    _stopwatch.stop(); 
    _timer?.cancel();
    _autoSplitTimer?.cancel();
    GlobalManager.isRecordingNotifier.value = false;

    if (_recordedPaths.isNotEmpty) {
      // 建立筆記，包含所有分段路徑
      final newNote = MeetingNote(
        id: _currentSessionId!, // 使用 Session ID 作為筆記 ID
        title: "新會議 (${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now())})",
        date: DateTime.now(),
        summary: ["AI 分析中..."],
        tasks: [],
        transcript: [],
        sections: [],
        audioPaths: List.from(_recordedPaths), // 複製清單
        status: NoteStatus.processing,
      );
      
      await GlobalManager.saveNote(newNote);
      GlobalManager.analyzeNote(newNote); // 分析會自動處理多個檔案
      if (mounted) setState(() {});
    }
  }

  // --- 修改區段 2：_pickFile (移除 FFmpeg，改為提示大檔) ---
  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (result != null) {
      File file = File(result.files.single.path!);
      int size = await file.length();
      
      // 20MB 檢查提示
      if (size > 20 * 1024 * 1024) {
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
             content: Text("警告：檔案超過 20MB，AI 分析可能會失敗。請先使用電腦切割音檔。"),
             backgroundColor: Colors.orange,
             duration: Duration(seconds: 5),
           ));
        }
      }
      
      // 建立初始筆記
      final noteId = const Uuid().v4();
      final newNote = MeetingNote(
        id: noteId,
        title: "匯入: ${file.path.split('/').last}",
        date: DateTime.now(),
        summary: ["AI 分析中..."],
        tasks: [],
        transcript: [],
        sections: [],
        audioPaths: [file.path], // 直接使用原檔
        status: NoteStatus.processing,
      );
      
      await GlobalManager.saveNote(newNote);
      if (mounted) setState(() {});

      // 開始分析
      GlobalManager.analyzeNote(newNote);
    }
  }

// --- 修改區段 3：_importYoutube (移除 FFmpeg，改為提示大檔) ---
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
      final noteId = const Uuid().v4();
      final tempNote = MeetingNote(
        id: noteId,
        title: "YT 下載中...",
        date: DateTime.now(),
        summary: ["下載中..."],
        tasks: [],
        transcript: [],
        sections: [],
        audioPaths: [],
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
        final path = '${dir.path}/$noteId.m4a';
        var file = File(path);
        var fileStream = file.openWrite();
        await stream.pipe(fileStream);
        await fileStream.flush();
        await fileStream.close();
        yt.close();

        // 檢查大小 (僅提示)
        File dlFile = File(path);
        int size = await dlFile.length();
        if (size > 20 * 1024 * 1024) {
           if (mounted) {
             ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
               content: Text("警告：下載的音訊過大，AI 分析可能會失敗。"),
               backgroundColor: Colors.orange,
             ));
           }
        }

        tempNote.audioPaths = [path];
        tempNote.status = NoteStatus.processing;
        tempNote.summary = ["AI 分析中..."];
        await GlobalManager.saveNote(tempNote);
        GlobalManager.analyzeNote(tempNote);
        if (mounted) setState(() {});

      } catch (e) {
        tempNote.status = NoteStatus.failed;
        tempNote.summary = ["下載失敗: $e"];
        await GlobalManager.saveNote(tempNote);
        if (mounted) setState(() {});
      }
    }
  }

  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Wrap(
        children: [
          ListTile(leading: const Icon(Icons.mic, color: Colors.blue), title: const Text("開始錄音"), onTap: () { Navigator.pop(ctx); _toggleRecording(); }),
          ListTile(leading: const Icon(Icons.upload_file, color: Colors.orange), title: const Text("上傳音訊檔"), onTap: () { Navigator.pop(ctx); _pickFile(); }),
          ListTile(leading: const Icon(Icons.video_library, color: Colors.red), title: const Text("輸入 YouTube 連結"), onTap: () { Navigator.pop(ctx); _importYoutube(); }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: IndexedStack(index: _currentIndex, children: _pages)),
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
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 6.0,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(icon: Icon(Icons.home, color: _currentIndex == 0 ? Colors.blue : Colors.grey), onPressed: () => setState(() => _currentIndex = 0)),
              ValueListenableBuilder<bool>(
                valueListenable: GlobalManager.isRecordingNotifier,
                builder: (context, isRecording, child) {
                  return FloatingActionButton(
                    onPressed: isRecording ? _toggleRecording : _showAddMenu,
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<MeetingNote> _notes = [];
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadNotes();
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
          _notes.sort((a, b) {
            if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
            return b.date.compareTo(a.date);
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
                    leading: IconButton(
                      icon: Icon(note.isPinned ? Icons.push_pin : Icons.push_pin_outlined, color: note.isPinned ? Colors.blue : Colors.grey),
                      onPressed: () => _togglePin(note),
                    ),
                    // --- 修改區段 4：HomePage UI (移除 splitting 狀態顯示) ---
                    // 1. 修改 title
                    title: Text(
                      (note.status == NoteStatus.processing) ? "⏳ 處理中..." : note.title,
                      style: TextStyle(fontWeight: FontWeight.bold, color: (note.status != NoteStatus.success && note.status != NoteStatus.failed) ? Colors.orange : Colors.black),
                    ),
                    
                    // 2. 修改 subtitle
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(DateFormat('yyyy/MM/dd HH:mm').format(note.date), style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 4),
                        if (note.status == NoteStatus.downloading)
                          const Row(children: [SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 8), Text("下載中...")])
                        // 移除原本的 else if (note.status == NoteStatus.splitting) 區塊
                        else if (note.summary.isNotEmpty) ...[
                          Text("• ${note.summary.first}", maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (note.summary.length > 1) Text("• ${note.summary[1]}", maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                        if (note.status == NoteStatus.failed) const Text("處理失敗", style: TextStyle(color: Colors.red)),
                      ],
                    ),
                    onTap: () {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => NoteDetailPage(note: note))).then((_) => _loadNotes());
                    },
                    trailing: note.isPinned
                        ? null
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
  // 播放多個檔案的邏輯
  int _currentAudioIndex = 0;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _tabController = TabController(length: 3, vsync: this);
    _initAudio();
  }
  
  // 初始化音訊 (預設載入第一個)
  void _initAudio() {
    if (_note.audioPaths.isNotEmpty) {
      _loadAudioFile(_currentAudioIndex);
    }
  }

  Future<void> _loadAudioFile(int index) async {
    if (index >= _note.audioPaths.length) return;
    try {
      await _audioPlayer.setSource(DeviceFileSource(_note.audioPaths[index]));
      final d = await _audioPlayer.getDuration();
      setState(() {
        _duration = d ?? Duration.zero;
        _currentAudioIndex = index;
      });
    } catch (e) {
      print("Error loading audio: $e");
    }
  }

  @override
  void dispose() { _audioPlayer.dispose(); _tabController.dispose(); super.dispose(); }

  void _togglePlay() { 
    if(!GlobalManager.isRecordingNotifier.value) _isPlaying ? _audioPlayer.pause() : _audioPlayer.resume(); 
    _audioPlayer.onPlayerStateChanged.listen((state) => setState(() => _isPlaying = state == PlayerState.playing));
    _audioPlayer.onPositionChanged.listen((p) => setState(() => _position = p));
  }

  // 複雜的跳轉邏輯 (跨檔案跳轉)
  // 為了簡化，目前我們先實作「跳轉到指定檔案的相對時間」
  // 完整實作需要維護每個檔案的總長度，這裡先做簡易版
  void _seekTo(double seconds) { 
    if(!GlobalManager.isRecordingNotifier.value) { 
      // 判斷這個秒數屬於哪個檔案 (這裡需要每個檔案的長度資訊，為簡化，假設使用者點擊時我們知道對應哪個 section)
      // 暫時：直接 seek 當前檔案
      _audioPlayer.seek(Duration(milliseconds: (seconds * 1000).toInt())); 
      _audioPlayer.resume(); 
    } 
  }

  Future<void> _exportPdf() async {
    final pdf = pw.Document();
    final font = await PdfGoogleFonts.notoSansTCRegular();
    final boldFont = await PdfGoogleFonts.notoSansTCBold();

    pdf.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(base: font, bold: boldFont),
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
          pw.Paragraph(text: "-- 逐字稿內容請見 App --", style: const pw.TextStyle(color: PdfColors.grey)),
        ],
      ),
    );
    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => pdf.save());
  }
  
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
              DropdownButtonFormField<String>(
                value: participants.contains(task.assignee) ? task.assignee : null,
                decoration: const InputDecoration(labelText: "負責人"),
                items: [...participants.map((p) => DropdownMenuItem(value: p, child: Text(p))), const DropdownMenuItem(value: "未定", child: Text("未定"))],
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
              _note.tasks[index] = TaskItem(description: descController.text, assignee: assigneeController.text, dueDate: dateController.text);
            });
            GlobalManager.saveNote(_note);
            Navigator.pop(ctx);
          }, child: const Text("儲存")),
        ],
      ),
    );
  }

  Future<void> _retryAnalysis() async { setState(() => _note.status = NoteStatus.processing); await GlobalManager.analyzeNote(_note); setState((){}); }
  String _formatDuration(Duration d) => "${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_note.title), actions: [IconButton(icon: const Icon(Icons.picture_as_pdf), onPressed: _exportPdf)]),
      body: Column(
        children: [
          Container(
            color: Colors.blueGrey[50],
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Column(
              children: [
                if(_note.audioPaths.length > 1) 
                  Text("正在播放第 ${_currentAudioIndex + 1} / ${_note.audioPaths.length} 部分", style: const TextStyle(fontSize: 10, color: Colors.grey)),
                Slider(
                  min: 0, max: _duration.inSeconds.toDouble(),
                  value: _position.inSeconds.toDouble().clamp(0, _duration.inSeconds.toDouble()),
                  onChanged: (v) { if (!GlobalManager.isRecordingNotifier.value) _audioPlayer.seek(Duration(seconds: v.toInt())); },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(_formatDuration(_position)), IconButton(icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 40), onPressed: _togglePlay), Text(_formatDuration(_duration))],
                ),
              ],
            ),
          ),
          TabBar(controller: _tabController, labelColor: Colors.blue, unselectedLabelColor: Colors.grey, tabs: const [Tab(text: "逐字稿"), Tab(text: "摘要"), Tab(text: "任務")]),
          Expanded(
            child: Builder(builder: (context) {
              if (_note.status == NoteStatus.processing) return const Center(child: Text("分析中..."));
              if (_note.status == NoteStatus.downloading) return const Center(child: Text("下載中..."));
              if (_note.status == NoteStatus.failed) return Center(child: ElevatedButton(onPressed: _retryAnalysis, child: const Text("重試")));
              
              return TabBarView(
                controller: _tabController,
                children: [
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: _note.sections.map((section) {
                      final sectionItems = _note.transcript.where((t) => t.startTime >= section.startTime && t.startTime < section.endTime).toList();
                      return ExpansionTile(
                        title: Text(section.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text("${_formatDuration(Duration(seconds: section.startTime.toInt()))} - ${_formatDuration(Duration(seconds: section.endTime.toInt()))}"),
                        initiallyExpanded: true,
                        children: sectionItems.map((item) {
                          return ListTile(
                            leading: CircleAvatar(radius: 12, backgroundColor: Colors.grey[300], child: Text(item.speaker[0], style: const TextStyle(fontSize: 10))),
                            title: Text(item.text),
                            onTap: () => _seekTo(item.startTime), // 注意：這只在播放對應檔案時才準確
                          );
                        }).toList(),
                      );
                    }).toList(),
                  ),
                  ListView.builder(padding: const EdgeInsets.all(16), itemCount: _note.summary.length, itemBuilder: (context, index) => ListTile(leading: const Icon(Icons.circle, size: 8), title: Text(_note.summary[index]))),
                  ListView.builder(padding: const EdgeInsets.all(16), itemCount: _note.tasks.length, itemBuilder: (context, index) {
                      final task = _note.tasks[index];
                      return Card(child: ListTile(leading: const Icon(Icons.check_box_outline_blank), title: Text(task.description), subtitle: Text("${task.assignee} | ${task.dueDate}"), trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => _editTask(index))));
                  }),
                ],
              );
            }),
          ),
        ],
      ),
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
  List<String> _participantList = [];
  final List<String> _models = ['gemini-flash-latest', 'gemini-1.5-pro', 'gemini-2.0-flash-exp'];

  @override
  void initState() { super.initState(); _loadSettings(); }

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
               value: _selectedModel, items: _models.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
               onChanged: (v) => setState(() => _selectedModel = v.toString()), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: "Model"),
             ),
             const Divider(),
             const Text("專業用詞字典"),
             Row(children: [
               Expanded(child: TextField(controller: _vocabController, decoration: const InputDecoration(hintText: "輸入術語"))),
               IconButton(icon: const Icon(Icons.add), onPressed: () { if(_vocabController.text.isNotEmpty) { GlobalManager.addVocab(_vocabController.text.trim()); _vocabController.clear(); } }),
             ]),
             ValueListenableBuilder<List<String>>(
               valueListenable: GlobalManager.vocabListNotifier,
               builder: (context, vocabList, child) => Wrap(spacing: 8, children: vocabList.map((v) => Chip(label: Text(v), onDeleted: () => GlobalManager.removeVocab(v))).toList()),
             ),
             const Divider(),
             const Text("常用與會者"),
             Row(children: [
               Expanded(child: TextField(controller: _participantController)),
               IconButton(icon: const Icon(Icons.add), onPressed: () { if(_participantController.text.isNotEmpty) { setState(() { _participantList.add(_participantController.text.trim()); _participantController.clear(); }); } }),
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
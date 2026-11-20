import Foundation

struct UsageAboutContent {
    struct GuideSection {
        let symbol: String
        let title: String
        let steps: [String]
    }

    struct ModelGroup {
        let title: String
        let models: [Model]
    }

    struct Model {
        let name: String
        let author: String
        let role: String
        let url: URL

        init(_ name: String, _ author: String, _ role: String, _ repository: String) {
            self.name = name
            self.author = author
            self.role = role
            self.url = URL(string: "https://github.com/")!.appendingPathComponent(repository)
        }
    }

    struct ProjectLink {
        let title: String
        let url: URL
    }

    let language: SubtitleLanguage

    private func text(_ simplified: String, _ traditional: String, _ english: String, _ japanese: String) -> String {
        switch language {
        case .simplifiedChinese: return simplified
        case .traditionalChinese: return traditional
        case .english: return english
        case .japanese: return japanese
        }
    }

    var guideTitle: String { text("使用指南", "使用指南", "Guide", "使い方") }
    var aboutTitle: String { text("关于 SimuSub", "關於 SimuSub", "About SimuSub", "SimuSub について") }

    var guideSections: [GuideSection] {
        [
            GuideSection(symbol: "captions.bubble", title: text("开启同传字幕", "開啟同步字幕", "Start live subtitles", "リアルタイム字幕を表示する"), steps: [
                text("先在浏览器或播放器里播放直播或视频。打开「字幕同传」，在「声音来源」中点正在播放的那个应用。",
                     "先在瀏覽器或播放器裡播放直播或影片。開啟「字幕同傳」，在「聲音來源」中點選正在播放的 App。",
                     "Play a stream or video in your browser or player. Open Live subtitles and choose that app under Audio source.",
                     "ブラウザやプレーヤーで配信・動画を再生します。「リアルタイム字幕」を開き、「音声ソース」で再生中のアプリを選びます。"),
                text("在「源语言」选你听到的中文、英语或日语，在「翻译为」选想看的语言，然后点「开始同传」。模型就绪后，字幕会出现在浮窗里。",
                     "在「源語言」選擇你聽到的中文、英語或日語，在「翻譯為」選擇想閱讀的語言，再點「開始同傳」。模型就緒後，字幕會顯示在浮動視窗中。",
                     "Set Source language to the Chinese, English or Japanese you hear. Under Translate to, choose the language you want to read. Click Start subtitles to open the floating subtitle window once the models are ready.",
                     "「元の言語」で聞こえてくる中国語・英語・日本語のいずれかを、「翻訳先」で読みたい言語を選びます。「字幕を開始」を押すと、モデルの準備ができ次第、字幕ウインドウが開きます。"),
                text("首次使用若提示缺少模型，确认下载大小后点「准备本地字幕」。准备完成会自动开始，中断后可点「重试」。若 macOS 请求录制权限，从提示打开系统设置，允许 SimuSub 录制音频，再按提示返回或重新打开应用。",
                     "首次使用若提示缺少模型，確認下載大小後點「準備本地字幕」。準備完成後會自動開始，中斷後可點「重試」。若 macOS 要求錄製權限，請依提示開啟系統設定，允許 SimuSub 錄製音訊，再依提示返回或重新開啟 App。",
                     "If models are missing, check the download size and click Prepare local subtitles. Subtitles start automatically when preparation finishes. Click Retry after an interruption. If macOS asks for recording permission, open System Settings from the prompt, allow audio capture for SimuSub, and return or reopen the app as directed.",
                     "モデルが足りないときは、容量を確認して「ローカル字幕を準備」を押します。準備が済むと字幕が始まります。中断した場合は「再試行」を押してください。macOS が収録の許可を求めたら、案内からシステム設定を開き、SimuSub に収録を許可してから、指示に従ってアプリに戻るか開き直します。"),
                text("想保留字幕，在浮窗点「导出字幕」。选 TXT 可保存纯文本，选 SRT 或 VTT 可保留时间码。",
                     "想保留字幕時，在浮動視窗點「導出字幕」。選 TXT 可儲存純文字，選 SRT 或 VTT 可保留時間碼。",
                     "To keep the subtitles, click Export subtitles in the floating window. Choose TXT for plain text, or SRT or VTT to keep the timings.",
                     "字幕を保存するには、字幕ウインドウで「字幕を書き出す」を押します。文章だけなら TXT、時刻も残すなら SRT または VTT を選びます。")
            ]),
            GuideSection(symbol: "record.circle", title: text("录下一场直播", "錄下一場直播", "Record a stream", "配信を録画する"), steps: [
                text("打开「直播录制」，点「添加主播」。选择平台，搜索主播或粘贴频道链接，从结果中添加主播。",
                     "開啟「直播錄製」，點「添加主播」。選擇平台，搜尋實況主或貼上頻道連結，從結果中加入實況主。",
                     "In Live recording, click Add creator. Select the platform, then search for a creator or paste a channel link. Add the creator from the results.",
                     "「ライブ録画」で「配信者を追加」を押します。プラットフォームを選び、配信者を検索するかチャンネルのリンクを貼り付けて、検索結果から追加します。"),
                text("开播后点主播旁的录制按钮，再点一次可停止。要找录好的视频，点同一行的「…」，选「打开录制文件夹」。",
                     "開播後點實況主旁的錄製按鈕，再點一次即可停止。要找錄好的影片，點同一列的「…」，選「打開錄製文件夾」。",
                     "Once the stream is live, click the record button beside the creator. Click it again to stop. To find the video, open the … menu in that row and choose Open recordings folder.",
                     "配信が始まったら、配信者の横にある録画ボタンを押します。もう一度押すと停止します。録画した動画は、同じ行の「…」から「録画フォルダを開く」で確認できます。")
            ]),
            GuideSection(symbol: "scissors", title: text("剪出想分享的一段", "剪出想分享的一段", "Make a clip to share", "共有したい場面を切り出す"), steps: [
                text("把视频拖进「剪辑工作台」，或从「项目与录制历史」打开一段录制。新项目先点时间轴上方的「＋」创建第一个选段，再拖动选段两端，对准想保留的开头和结尾。",
                     "把影片拖進「剪輯工作台」，或從「項目與錄製歷史」開啟一段錄影。新專案先點時間軸上方的「＋」建立第一個選段，再拖曳選段兩端，對準想保留的開頭和結尾。",
                     "Drag a video into Clip studio or open a recording from Projects & recordings. In a new project, click + above the timeline to create the first range. Drag its ends to the start and end of the moment you want to keep.",
                     "「クリップ編集」に動画をドラッグするか、「プロジェクトと録画履歴」から録画を開きます。新しいプロジェクトでは、まずタイムラインの上の「＋」で最初の区間を作ります。区間の両端をドラッグして、残したい場面に合わせます。"),
                text("先在编辑器上方选好源语言和字幕语言。在「字幕」区，点波形生成字幕，或点带加号的文件图标导入已有字幕。点画笔调整样式，点字幕行的时间修改文字和出现时间。",
                     "先在編輯器上方選好來源語言和字幕語言。在「字幕」區，點波形產生字幕，或點帶加號的文件圖示匯入現有字幕。點畫筆調整樣式，點字幕列上的時間修改文字和顯示時間。",
                     "Choose the source and subtitle languages at the top of the editor. In the subtitle panel, click the waveform to generate subtitles or the document with a plus sign to import a file. Click the brush to adjust the style, or a line’s timestamp to edit its text and timing.",
                     "編集画面の上部で元の言語と翻訳先を選びます。字幕欄の波形で字幕を生成し、＋付きの書類アイコンで字幕ファイルを読み込めます。筆でスタイルを調整し、各行の時刻を押すと文面や表示時間を変更できます。"),
                text("点双人图标可以添加和管理多个角色。点一行字幕旁的数字，为这一行选择一个角色。0 是片段默认样式，自建角色从 1 开始，每个角色的编号固定。",
                     "點雙人圖示可新增和管理多個角色。點一列字幕旁的數字，為這列字幕選一個角色。0 是片段預設樣式，自訂角色從 1 開始，每個角色的編號固定。",
                     "Click the two-person icon to add or manage roles. Click the number beside a subtitle line to choose its role. 0 uses the clip’s default style. Each role you add keeps its own number, starting at 1.",
                     "二人の人物のアイコンで役を追加・管理できます。各字幕の横の番号を押して、その行の役を一つ選びます。0 はクリップの標準スタイルです。追加した役には 1 から番号が付き、同じ役には常に同じ番号が表示されます。"),
                text("点「导出片段」，勾选要分享的选段并开始导出。只想要字幕文件时，点「字幕」区的「…」，选「导出字幕」。",
                     "點「導出片段」，勾選想分享的選段後開始匯出。如果只需要字幕檔，點「字幕」區的「…」，選「導出字幕」。",
                     "Click Export clips, select the ranges you want to share, and start the export. For a subtitle file, open the … menu in the subtitle panel and choose Export subtitles.",
                     "「クリップを書き出す」を押し、共有したい区間にチェックを入れて書き出します。字幕ファイルだけが必要なときは、字幕欄の「…」から「字幕を書き出す」を選びます。")
            ])
        ]
    }

    var licenseTitle: String { text("项目许可", "專案授權", "Project license", "ライセンス") }
    var licenseSummary: String {
        text("SimuSub 使用 MIT 协议。", "SimuSub 使用 MIT 授權條款。", "SimuSub uses the MIT License.", "SimuSub は MIT ライセンスを採用しています。")
    }
    var licenseLinkTitle: String { text("阅读完整 MIT 许可证", "閱讀完整 MIT 授權條款", "Read the full MIT License", "MIT ライセンスの全文を読む") }
    var originTitle: String { text("为什么做 SimuSub", "為什麼做 SimuSub", "Why I made SimuSub", "SimuSub を作ったきっかけ") }
    var originBody: String {
        text("我最初想给 VTuber 做一个同传字幕工具。Simu 取「同步」的意思，Sub 来自 Subtitle，也就是字幕。\n\n看直播时，总有那么几秒，想回头再看一遍，也想让朋友看看。我希望观众能亲手剪下自己喜欢的一段，让那些可能再也看不到的瞬间留下来。",
             "我最初想為 VTuber 做一個即時字幕工具。Simu 取「同步」的意思，Sub 來自 Subtitle，也就是字幕。\n\n看直播時，總有那麼幾秒，想倒回去再看一遍，也想讓朋友看看。我希望觀眾能親手剪下喜歡的片段，留下那些可能再也看不到的瞬間。",
             "I started SimuSub to make live subtitles for VTubers. Simu is about keeping the words in sync with the stream. Sub comes from “subtitle”.\n\nWhen I watch a stream, there are always a few seconds I want to see again or show a friend. I wanted viewers to be able to clip those moments themselves, so they could keep something that might otherwise disappear.",
             "もともとは VTuber のために、配信に合わせて字幕を出すツールを作りたいと思っていました。Simu には「同期」の意味を込め、Sub は字幕を表す Subtitle から取りました。\n\n配信を観ていると、もう一度観たい、友達にも見せたいと思う数秒間があります。観ていた人が自分の手で好きな場面を切り出して、二度と観られなくなるかもしれない瞬間を残せたらと思っています。")
    }
    var modelsTitle: String { text("本地模型", "本機模型", "Local models", "ローカルモデル") }
    var modelsIntro: String {
        text("谢谢把这些模型开放出来的开发者。没有你们的工作，就没有 SimuSub。各模型及权重的许可条款请以提供者的说明为准。",
             "謝謝願意公開這些模型的開發者。沒有你們的工作，就沒有 SimuSub。各模型與權重的授權條款請以提供者的說明為準。",
             "Thank you to the developers who shared these models. Without your work, SimuSub would never have existed. Each provider sets the terms for its models and weights.",
             "これらのモデルを公開してくださった開発者の皆さんに感謝しています。皆さんの仕事があったからこそ SimuSub を作れました。各モデルと重みには提供元の利用条件が適用されます。")
    }
    var modelGroups: [ModelGroup] {
        let standard = text("默认", "預設", "Default", "標準")
        let optional = text("可选", "可選", "Optional", "任意")
        let included = text("随包", "隨附", "Included", "同梱")
        return [
            ModelGroup(title: text("语音识别", "語音辨識", "Speech recognition", "音声認識"), models: [
                Model("SenseVoice Small INT8", "FunAudioLLM / QwenAudio", standard + " · " + text("中文", "中文", "Chinese", "中国語"), "QwenAudio/SenseVoice"),
                Model("Whisper Base INT8", "OpenAI", standard + " · " + text("英语", "英語", "English", "英語"), "openai/whisper"),
                Model("ReazonSpeech k2 v2", "Reazon Human Interaction Lab", standard + " · " + text("日语", "日語", "Japanese", "日本語"), "reazon-research/ReazonSpeech"),
                Model("Whisper Small INT8", "OpenAI", optional, "openai/whisper"),
                Model("Qwen3-ASR 0.6B INT8", "Qwen Team", optional, "QwenLM/Qwen3-ASR")
            ]),
            ModelGroup(title: text("字幕翻译", "字幕翻譯", "Subtitle translation", "字幕翻訳"), models: [
                Model("Index-Translate-2B Q4_K_M", "bilibili Index Team", standard, "bilibili/Index-Translate"),
                Model("HY-MT1.5 1.8B Q4_K_M", "Tencent Hunyuan", optional, "Tencent-Hunyuan/Hy-MT"),
                Model("Gemma 4 E2B / E4B QAT Q4_0", "Google DeepMind", optional, "google-deepmind/gemma")
            ]),
            ModelGroup(title: text("人声处理与字幕断行", "人聲處理與字幕分行", "Speech processing and subtitle line breaks", "音声処理と字幕の改行"), models: [
                Model("Silero VAD", "Silero Team", included + " · " + text("检测人声", "偵測語音", "Speech detection", "発話区間の検出"), "snakers4/silero-vad"),
                Model("GTCRN", "Xiaobin Rong", included + " · " + text("语音降噪", "語音降噪", "Speech enhancement", "音声のノイズ抑制"), "Xiaobin-Rong/gtcrn"),
                Model("BudouX", "Google", included + " · " + text("中日文字幕断行", "中日文字幕分行", "Chinese and Japanese line breaks", "中国語・日本語字幕の改行"), "google/budoux")
            ])
        ]
    }
    var mentorTitle: String { text("致谢", "致謝", "Acknowledgments", "謝辞") }
    var mentorBody: String {
        text("最后，谢谢我的导师 frank，指导我把这个项目写了出来。", "最後，謝謝我的導師 frank，指導我把這個專案寫了出來。",
             "Finally, thank you to my mentor, frank, for guiding me as I built SimuSub.",
             "最後に、SimuSub を作るにあたって指導してくださったメンターの frank さんに感謝します。")
    }
    var mentorLink: ProjectLink {
        ProjectLink(title: text("frank 的 B 站主页", "frank 的 B 站主頁", "frank on Bilibili", "frank の Bilibili"),
                    url: URL(string: "https://space.bilibili.com/19658621")!)
    }
}

import SwiftUI

struct UsageAboutSettingsView: View {
    enum Page { case guide, about }

    @ObservedObject private var localization = AppLocalization.shared
    @State private var page: Page

    init(initialPage: Page = .guide) {
        _page = State(initialValue: initialPage)
    }

    private func t(_ zh: String, _ en: String, _ ja: String) -> String {
        switch localization.language {
        case .simplifiedChinese: return zh
        case .traditionalChinese: return localization.language.normalizeScript(zh)
        case .english: return en
        case .japanese: return ja
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(t("使用说明", "User guide", "使い方"), selection: $page) {
                Text(t("使用指南", "Guide", "使い方")).tag(Page.guide)
                Text(t("关于 SimuSub", "About SimuSub", "SimuSub について")).tag(Page.about)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
            .accessibilityIdentifier("usage.page")

            switch page {
            case .guide: guide
            case .about: about
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("captions.bubble", L10n.text("字幕同传")) {
                paragraph(t(
                    "先播放直播或视频。在「声音来源」中点选正在播放的应用，把「源语言」设为听到的中文、英语或日语，在「翻译为」里选想看的字幕语言，再点「开始同传」。下次打开时会记住语言选择。",
                    "Play the stream or video, then select its app under Audio source. Set Source language to the Chinese, English or Japanese you hear, choose the language you want to read under Translate to, and click Start subtitles. SimuSub remembers your language choices.",
                    "先に配信や動画を再生し、「音声ソース」で再生中のアプリを選びます。「元の言語」を聞こえてくる中国語・英語・日本語に合わせ、「翻訳先」で読みたい言語を選んで「字幕を開始」を押します。言語の選択は次回も引き継がれます。"))
                paragraph(t(
                    "首次使用时，SimuSub 会自动选好本地模型。如果还缺文件，确认下载大小后点「准备本地字幕」。准备完毕会自动开始，中断后可点「重试」继续使用已备好的文件。",
                    "SimuSub chooses the local models for you. If files are missing, review the download size and click Prepare local subtitles. Subtitles start when the files are ready. After an interruption, Retry reuses the files already prepared.",
                    "必要なローカルモデルは自動で選ばれます。ファイルが足りない場合はダウンロード容量を確認し、「ローカル字幕を準備」を押します。準備が済むと字幕が始まります。中断した場合は「再試行」で準備済みのファイルを引き継げます。"))
                paragraph(t(
                    "若 macOS 请求授权，打开页面上的系统录制权限设置，允许 SimuSub 采集音频。按系统提示返回或重新打开 SimuSub，必要时点「重试」。",
                    "If macOS asks for recording permission, open System Settings from the prompt and allow SimuSub to capture audio. Return to SimuSub, or reopen it if macOS asks. Click Retry if needed.",
                    "macOS に録音の許可を求められたら、画面のボタンからシステム設定を開き、SimuSub に音声の収録を許可します。表示に従ってアプリに戻るか開き直し、必要に応じて「再試行」を押します。"))
                paragraph(t(
                    "想对照着看，可以在「字幕外观」开启「显示原文」。在字幕浮窗里可以暂停同传、回看历史，或把字幕导出为 TXT、SRT 或 VTT。",
                    "Turn on Show original under Subtitle appearance to read both languages. Use the floating subtitle window to pause, review earlier lines, or export subtitles as TXT, SRT or VTT.",
                    "「字幕の外観」で「原文を表示」をオンにすると、原文と訳文を並べて読めます。字幕ウインドウでは一時停止、履歴の確認、TXT・SRT・VTT への書き出しができます。"))
            }
            section("record.circle", L10n.text("直播录制")) {
                paragraph(t(
                    "在「直播录制」中搜索并添加主播。开播后，点主播旁的录制按钮开始或停止录制。右键点主播可以设置开播提醒和自动录制。在「设置 → 录制与剪辑」里选择保存目录。",
                    "Find and add a channel in Live recording. When the channel goes live, use its record button to start or stop recording. Right-click the channel to set live notifications or automatic recording. Choose the save folder in Settings → Recording and editing.",
                    "「ライブ録画」で配信者を検索して追加します。配信が始まったら、配信者の横にある録画ボタンで録画を開始・停止できます。右クリックで配信開始の通知や自動録画を設定できます。保存先は「設定 → 録画と編集」で選びます。"))
            }
            section("scissors", L10n.text("剪辑工作台")) {
                paragraph(t(
                    "把视频拖进剪辑工作台，或从「项目与录制历史」打开一段录制。添加选段，在时间轴上调整起点和终点。可导入字幕文件，逐行修改文字和时间。勾选要分享的选段后，从导出菜单选择视频、音频或字幕。",
                    "Drag a video into Clip studio, or open a recording from Projects & recordings. Add a range and adjust its start and end on the timeline. You can import subtitles and edit each line’s text and timing. Select the ranges you want to share, then choose video, audio or subtitles from the export menu.",
                    "「クリップ編集」に動画をドラッグするか、「プロジェクトと録画履歴」から録画を開きます。区間を追加し、タイムライン上で始点と終点を調整します。字幕ファイルを読み込み、行ごとに文面や時刻を編集できます。共有したい区間にチェックを入れ、書き出しメニューで動画・音声・字幕を選びます。"))
            }
        }
        .accessibilityIdentifier("usage.guide")
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("doc.text", t("MIT 许可证", "MIT License", "MIT ライセンス")) {
                paragraph(t(
                    "我为 SimuSub 的源代码选择了 MIT 许可证，和 Nongfsq 的 ftop 一样。你可以使用、修改和分发这份代码，分发时请保留原有的版权声明和许可声明。",
                    "I chose the MIT License for SimuSub’s source code, just as Nongfsq did for ftop. You can use, modify and distribute the code. When distributing it, please keep the copyright and license notices.",
                    "SimuSub のソースコードには、Nongfsq さんの ftop と同じ MIT ライセンスを選びました。コードは利用・変更・再配布できます。配布の際は元の著作権表示と許諾表示を残してください。"))
                if let license = Self.licenseText {
                    DisclosureGroup(t("阅读许可证原文", "Read the license", "ライセンス原文を読む")) {
                        Text(verbatim: license)
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }
                }
                externalLink("Nongfsq/ftop · LICENSE", "https://github.com/Nongfsq/ftop/blob/main/LICENSE")
            }
            section("captions.bubble", t("SimuSub 的由来", "Why I made SimuSub", "SimuSub を作ったきっかけ")) {
                paragraph(t(
                    "最初，我想为 VTuber 做一款同传字幕工具。Simu 取「同步」的意思，Sub 来自 Subtitle，也就是字幕。",
                    "I started SimuSub because I wanted to make live subtitles for VTubers. Simu stands for staying in sync, and Sub comes from “subtitle.”",
                    "最初は VTuber のために、配信に合わせて字幕を届けるツールを作りたいと思いました。Simu には「同期」の意味を込め、Sub は字幕を表す Subtitle から取りました。"))
                paragraph(t(
                    "我也希望，看完一场直播后，观众能把自己喜欢的那一小段分享给别人。有些瞬间，错过就再也看不到了。我想让它们留下来。",
                    "I also wanted viewers to be able to share a piece of a stream they loved. Some moments disappear for good when the stream ends. I wanted to give people a way to keep them.",
                    "配信を観た人が、好きだった場面を誰かに分けられたら、とも思っています。配信が終われば、もう会えなくなる瞬間があります。そんな瞬間を残せるようにしたかったのです。"))
            }
            section("waveform", t("本地模型", "Local models", "ローカルモデル")) {
                paragraph(t(
                    "感谢愿意把模型开放出来的开发者和维护者。没有你们的工作，就没有 SimuSub。下列模型和权重各自遵循发布者的许可条款。",
                    "I’m grateful to the developers and maintainers who shared these models. Without your work, SimuSub would never have existed. Each model and its weights are governed by its publisher’s terms.",
                    "モデルを公開し、育ててくださった開発者とメンテナーの皆さんに感謝しています。皆さんの仕事があったからこそ、SimuSub を作れました。各モデルと重みには、それぞれの提供元の利用条件が適用されます。"))
                modelGroup(t("默认识别与翻译", "Default recognition and translation", "標準の音声認識・翻訳")) {
                    model("ReazonSpeech k2 v2", "Reazon Human Interaction Lab", t("日语识别", "Japanese speech", "日本語の音声認識"), "reazon-research/ReazonSpeech")
                    model("SenseVoice Small INT8", "FunAudioLLM / QwenAudio", t("中文识别", "Chinese speech", "中国語の音声認識"), "QwenAudio/SenseVoice")
                    model("Whisper Base INT8", "OpenAI", t("英语识别", "English speech", "英語の音声認識"), "openai/whisper")
                    model("Index-Translate-2B Q4_K_M", "bilibili Index Team", t("字幕翻译", "Subtitle translation", "字幕翻訳"), "bilibili/Index-Translate")
                }
                modelGroup(t("可选识别与翻译", "Optional recognition and translation", "選択できる音声認識・翻訳")) {
                    model("Whisper Small INT8", "OpenAI", L10n.text("语音识别"), "openai/whisper")
                    model("Qwen3-ASR 0.6B INT8", "Qwen Team", L10n.text("语音识别"), "QwenLM/Qwen3-ASR")
                    model("HY-MT1.5 1.8B Q4_K_M", "Tencent Hunyuan", L10n.text("翻译"), "Tencent-Hunyuan/Hy-MT")
                    model("Gemma 4 E2B / E4B QAT Q4_0", "Google DeepMind", L10n.text("翻译"), "google-deepmind/gemma")
                }
                modelGroup(t("随应用提供的模型", "Models included with the app", "アプリに同梱したモデル")) {
                    model("Silero VAD", "Silero Team", t("语音活动检测", "Speech detection", "発話区間の検出"), "snakers4/silero-vad")
                    model("GTCRN", "Xiaobin Rong", t("语音降噪", "Speech enhancement", "音声のノイズ抑制"), "Xiaobin-Rong/gtcrn")
                    model("BudouX", "Google", t("中日文字幕断行", "Chinese and Japanese line breaking", "中国語・日本語字幕の改行"), "google/budoux")
                }
            }
            section("person", t("致谢", "Acknowledgments", "謝辞")) {
                paragraph(t(
                    "最后，谢谢我的导师 frank，指导我写出了这个项目。",
                    "Finally, thank you to my mentor, frank, for guiding me as I built this project.",
                    "最後に、このプロジェクトを形にするまで指導してくださった、私のメンターの frank さんに感謝します。"))
                externalLink(t("frank 的 B 站主页", "frank on Bilibili", "frank さんの Bilibili"), "https://space.bilibili.com/19658621")
            }
        }
        .accessibilityIdentifier("usage.about")
    }

    private static let licenseText: String? = {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private func section<Content: View>(_ icon: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .interfaceFont(size: 16, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .designPanel()
    }

    private func paragraph(_ text: String) -> some View {
        Text(verbatim: text)
            .interfaceFont(size: 13)
            .foregroundStyle(ThemeColor.ink)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func modelGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).interfaceFont(size: 13, weight: .semibold).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, 4)
    }

    private func model(_ name: String, _ provider: String, _ role: String, _ repository: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            externalLink(name, "https://github.com/" + repository)
            Text(verbatim: "\(provider) · \(role)").interfaceFont(size: 12).foregroundStyle(ThemeColor.muted)
        }
    }

    private func externalLink(_ title: String, _ address: String) -> some View {
        Link(destination: URL(string: address)!) {
            Text(verbatim: title).underline()
                .fixedSize(horizontal: false, vertical: true)
        }
        .interfaceFont(size: 13)
        .foregroundStyle(ThemeColor.primaryInk)
        .help(address)
    }
}

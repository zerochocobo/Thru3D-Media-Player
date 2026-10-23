package org.vrpassthroughplayer.plugin

/** Shared sample text, checked 2026-10-23. All translations preserve the sample meaning.
 * Text only: each selected voice synthesizes its sample on demand, with no bundled WAVs.
 */
internal object VoiceClonePreviewText {
    private val texts = linkedMapOf(
        "zh" to "你好，很高兴认识你。今天天气很舒服，我们可以聊聊最近的计划、喜欢的音乐，也分享一些温暖有趣的想法。",
        "en" to "Hello, it's nice to meet you. The weather is lovely today. We can talk about our recent plans and favorite music, and share some warm, interesting ideas.",
        "ja" to "こんにちは、お会いできてうれしいです。今日は気持ちのよい天気ですね。最近の計画や好きな音楽について話したり、心温まる面白いアイデアを分かち合ったりしましょう。",
        "de" to "Hallo, schön, dich kennenzulernen. Das Wetter ist heute angenehm. Wir können über unsere neuesten Pläne und Lieblingsmusik sprechen und herzliche, interessante Gedanken teilen.",
        "es" to "Hola, me alegra conocerte. Hoy hace un tiempo agradable. Podemos hablar de nuestros planes recientes y de la música que nos gusta, y compartir ideas cálidas e interesantes.",
        "fr" to "Bonjour, quel plaisir de vous rencontrer. Il fait bon aujourd'hui. Parlons de nos projets récents, de la musique que nous aimons et partageons des idées chaleureuses et intéressantes.",
        "it" to "Ciao, è un piacere conoscerti. Oggi il tempo è piacevole. Possiamo parlare dei nostri ultimi progetti e della musica che amiamo, e condividere pensieri affettuosi e interessanti.",
        "hu" to "Szia, örülök, hogy megismerhetlek. Ma kellemes az idő. Beszélgethetünk a mostani terveinkről, a kedvenc zenéinkről, és megoszthatunk néhány szívmelengető, érdekes gondolatot.",
        "ko" to "안녕하세요, 만나서 반갑습니다. 오늘은 날씨가 참 쾌적하네요. 요즘 세운 계획이나 좋아하는 음악에 대해 이야기하고, 따뜻하고 재미있는 생각도 나눠 봐요.",
        "ru" to "Здравствуйте, приятно познакомиться. Сегодня приятная погода. Мы можем поговорить о недавних планах, любимой музыке и поделиться тёплыми и интересными мыслями.",
        "fa" to "سلام، از آشنایی با شما خوشحالم. امروز هوا دلپذیر است. می‌توانیم دربارهٔ برنامه‌های اخیر و موسیقی مورد علاقه‌مان صحبت کنیم و چند فکر دلگرم‌کننده و جالب را با هم در میان بگذاریم.",
        "ar" to "مرحبًا، يسعدني التعرف عليك. الطقس لطيف اليوم. يمكننا التحدث عن خططنا الأخيرة والموسيقى التي نحبها، ومشاركة بعض الأفكار الدافئة والممتعة.",
        "pl" to "Cześć, miło cię poznać. Dziś jest przyjemna pogoda. Możemy porozmawiać o naszych ostatnich planach, ulubionej muzyce i podzielić się ciepłymi, ciekawymi myślami.",
        "pt" to "Olá, é um prazer conhecer você. O tempo está agradável hoje. Podemos conversar sobre nossos planos recentes, a música de que gostamos e compartilhar ideias acolhedoras e interessantes.",
        "cs" to "Ahoj, těší mě, že se poznáváme. Dnes je příjemné počasí. Můžeme si popovídat o našich posledních plánech, oblíbené hudbě a podělit se o hřejivé a zajímavé myšlenky.",
        "da" to "Hej, det er dejligt at møde dig. Vejret er behageligt i dag. Vi kan tale om vores seneste planer, den musik, vi holder af, og dele nogle varme og spændende tanker.",
        "sv" to "Hej, trevligt att träffas. Vädret är behagligt i dag. Vi kan prata om våra senaste planer, musiken vi tycker om och dela några varma och intressanta tankar.",
        "el" to "Γεια σου, χαίρομαι που σε γνωρίζω. Ο καιρός είναι ευχάριστος σήμερα. Μπορούμε να μιλήσουμε για τα πρόσφατα σχέδιά μας, την αγαπημένη μας μουσική και να μοιραστούμε ζεστές, ενδιαφέρουσες σκέψεις.",
        "tr" to "Merhaba, tanıştığımıza memnun oldum. Bugün hava çok güzel. Son planlarımızdan, sevdiğimiz müziklerden konuşabilir, içimizi ısıtan ilginç düşünceler paylaşabiliriz.")
    val languages: Set<String> = texts.keys
    fun text(language: String): String = requireNotNull(texts[language]) { "unsupported_language" }
}

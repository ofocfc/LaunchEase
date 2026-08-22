(() => {
  const root = document.documentElement;
  const configuredRepository = root.dataset.repository?.trim();

  const englishText = {
    "体验": "Experience",
    "功能": "Features",
    "开源": "Open Source",
    "免费下载": "Free Download",
    "免费 · 开源 · 本地运行": "Free · Open Source · Local-first",
    "把熟悉的启动台": "Bring the familiar Launchpad",
    "带回你的 Mac。": "back to your Mac.",
    "LaunchEase 用跟手翻页、清晰的应用网格、自由整理和完整辅助功能，让寻找应用重新变得简单。": "LaunchEase makes finding apps effortless again with fluid paging, a clear app grid, flexible organization, and complete accessibility support.",
    "免费下载 v1.1.0": "Free Download v1.1.0",
    "查看源代码": "View Source Code",
    "✓ 永久免费": "✓ Free forever",
    "✓ 无广告与账号": "✓ No ads or accounts",
    "四指手势": "Four-finger gestures",
    "自动适配 Dock": "Adaptive Dock layout",
    "真实的启动体验": "A familiar launch experience",
    "打开，就是熟悉的感觉。": "Open it. Feel right at home.",
    "壁纸、图标、搜索与程序坞自然地融在一起。没有多余窗口，也没有复杂操作。": "Wallpaper, icons, search, and the Dock blend naturally together—without extra windows or complicated controls.",
    "免费开源": "Free & Open Source",
    "我们的承诺": "Our promise",
    "真正免费，": "Truly free,",
    "也真正属于你。": "truly yours.",
    "没有试用期，没有会员，没有功能解锁。完整源码公开在 GitHub，你可以自由使用、查看和改进。": "No trials, subscriptions, or locked features. The complete source is available on GitHub for you to use, inspect, and improve.",
    "在 GitHub 查看项目": "View on GitHub",
    "永久免费": "Free forever",
    "所有核心功能完整开放，不设置付费门槛。": "Every core feature is available with no paywall.",
    "MIT 开源": "MIT licensed",
    "源代码公开透明，欢迎 Issue 与 Pull Request。": "Transparent source code, with issues and pull requests welcome.",
    "只在本地": "Local-first",
    "无需账号，不含遥测，不上传你的应用信息。": "No account, no telemetry, and no uploading your app information.",
    "保持纯粹": "Purposefully simple",
    "没有广告和推荐流，只专注于快速启动应用。": "No ads or feeds—just a faster way to launch apps.",
    "不只是好看": "More than good looks",
    "每一次操作，": "Every interaction,",
    "都自然得恰到好处。": "naturally responsive.",
    "从滚动翻页、程序坞拖放到完整键盘操作，LaunchEase 尽可能使用 macOS 熟悉的逻辑回应每一个动作。": "From fluid paging and Dock drag-and-drop to complete keyboard control, LaunchEase responds using interactions that already feel familiar on macOS.",
    "跟手翻页": "Fluid paging",
    "页面实时跟随触控板和鼠标滚轮移动，再自然停靠。首尾页不会循环跳转，页面圆点同步响应。": "Pages follow your trackpad or mouse wheel in real time, then settle naturally. Boundaries never wrap, and page indicators stay in sync.",
    "随手整理": "Effortless organization",
    "拖动图标改变位置，其他应用自动补位；重叠即可创建毛玻璃文件夹。": "Drag icons to rearrange them while other apps flow into place, or overlap two apps to create a glass folder.",
    "即时搜索": "Instant search",
    "保留应用原生名称，输入文字立即筛选，点击后启动并自动隐藏。": "Keep each app’s native name, filter as you type, and automatically hide LaunchEase after opening an app.",
    "扫描文件夹": "Scan folders",
    "布局": "Layout",
    "5 行 × 8 列": "5 rows × 8 columns",
    "程序坞适配": "Dock adaptation",
    "为你的屏幕而变": "Made for your screen",
    "自由设置扫描目录与行列数，图标尺寸和上下间距根据屏幕与程序坞大小自动计算。": "Choose scan locations, rows, and columns. Icon size and vertical spacing adapt automatically to your screen and Dock.",
    "手势与程序坞": "Gestures and Dock",
    "四指捏合打开、四指张开退出；应用图标可以自然拖入程序坞，启动和整理保持连贯。": "Pinch with four fingers to open and spread to close. Drag apps naturally into the Dock without breaking your flow.",
    "每个人都能轻松使用": "Accessible to everyone",
    "支持 VoiceOver、完整键盘导航，并跟随系统的“减少动态效果”“提高对比度”和“不使用颜色区分”。": "Supports VoiceOver, complete keyboard navigation, Reduce Motion, Increase Contrast, and Differentiate Without Color.",
    "扫描目录": "Scan locations",
    "已备份": "Backed up",
    "布局与文件夹": "Layout and folders",
    "一键恢复": "One-click restore",
    "设置随时带走": "Take your setup with you",
    "一键导出或导入扫描目录、行列布局、应用顺序、文件夹与图标设置，重装后也能快速恢复熟悉的启动台。": "Export or import scan locations, grid layout, app order, folders, and icon settings, then restore your familiar setup after reinstalling.",
    "看得见的代码，": "Code you can inspect.",
    "用得安心的软件。": "Software you can trust.",
    "LaunchEase 以 MIT License 开源。你可以检查每一行代码、提交建议，或构建属于自己的版本。": "LaunchEase is open source under the MIT License. Inspect every line, suggest improvements, or build a version of your own.",
    "打开 GitHub": "Open GitHub",
    "提交问题": "Report an Issue",
    "无需安装器": "No installer required",
    "下载，拖入，打开。": "Download. Drag. Open.",
    "整个过程只需要一分钟。": "It only takes a minute.",
    "下载 ZIP": "Download the ZIP",
    "获取最新的 LaunchEase.zip。": "Get the latest LaunchEase.zip.",
    "拖入应用程序": "Move to Applications",
    "将 App 放进“应用程序”文件夹。": "Move the app into your Applications folder.",
    "右键打开": "Right-click to open",
    "首次运行先右键应用并选择“打开”。": "Right-click the app and choose Open the first time you launch it.",
    "首次运行": "First launch",
    "提示“无法打开”时，请在系统设置中放行。": "If macOS says the app can’t be opened, allow it in System Settings.",
    "当前下载版尚未经过 Apple 公证。如果右键打开后仍被阻止，请按照下面的步骤操作：": "The current download has not yet been notarized by Apple. If right-clicking Open is still blocked, follow these steps:",
    "打开“系统设置 → 隐私与安全性”。": "Open System Settings → Privacy & Security.",
    "向下找到“安全性”区域，在 LaunchEase 提示旁点击“仍要打开”。": "Scroll down to Security and click Open Anyway beside the LaunchEase notice.",
    "使用 Touch ID 或输入 Mac 登录密码，然后再次确认“仍要打开”。": "Use Touch ID or enter your Mac login password, then confirm Open Anyway once more.",
    "仅在确认应用从 LaunchEase 官方 GitHub Releases 下载时执行此操作。": "Only do this when you downloaded the app from the official LaunchEase GitHub Releases page.",
    "让启动应用，再简单一点。": "A simpler way to launch apps.",
    "LaunchEase 免费、开源，并将一直专注于纯粹、顺滑且人人可用的 macOS 启动体验。": "LaunchEase is free and open source, built to keep launching apps simple, fluid, and accessible to everyone.",
    "免费下载 LaunchEase": "Download LaunchEase Free",
    "GitHub 源代码": "Source on GitHub",
    "约 11 MB · Apple 芯片 · macOS 26.5+": "About 11 MB · Apple silicon · macOS 26.5+",
    "免费开源的 macOS 应用启动台。": "A free and open-source app launcher for macOS.",
    "下载": "Download",
    "源代码": "Source Code",
    "问题反馈": "Feedback"
  };

  const englishAttributes = {
    "主导航": "Primary navigation",
    "返回顶部": "Back to top",
    "LaunchEase 应用图标": "LaunchEase app icon",
    "LaunchEase 最新启动台界面": "The latest LaunchEase app launcher interface",
    "产品特点": "Product highlights",
    "项目代码示意": "Project code preview",
    "首次打开说明": "First-launch instructions"
  };

  const metadata = {
    "zh-Hans": {
      title: "LaunchEase — 免费开源的 macOS 应用启动台",
      description: "LaunchEase 是一款免费开源、轻盈流畅且支持完整辅助功能的 macOS 应用启动台。",
      socialDescription: "跟手翻页、自由整理、键盘与 VoiceOver 支持。免费、开源、本地运行。"
    },
    en: {
      title: "LaunchEase — Free and Open-Source App Launcher for macOS",
      description: "LaunchEase is a free, open-source, fluid, and fully accessible app launcher for macOS.",
      socialDescription: "Fluid paging, flexible organization, keyboard and VoiceOver support. Free, open source, and local-first."
    }
  };

  const originalText = new WeakMap();
  const originalAttributes = new WeakMap();

  function translatedTextNodes() {
    const nodes = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (node.parentElement?.closest("script, style")) return NodeFilter.FILTER_REJECT;
        return node.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });

    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }

  function applyLanguage(language, updateAddress = false) {
    const normalizedLanguage = language === "en" ? "en" : "zh-Hans";
    root.lang = normalizedLanguage;

    translatedTextNodes().forEach((node) => {
      if (!originalText.has(node)) originalText.set(node, node.nodeValue);
      const source = originalText.get(node);
      const trimmed = source.trim();
      const replacement = normalizedLanguage === "en" ? englishText[trimmed] : undefined;
      node.nodeValue = replacement ? source.replace(trimmed, replacement) : source;
    });

    document.querySelectorAll("[aria-label], [alt]").forEach((element) => {
      if (!originalAttributes.has(element)) {
        originalAttributes.set(element, {
          ariaLabel: element.getAttribute("aria-label"),
          alt: element.getAttribute("alt")
        });
      }

      const source = originalAttributes.get(element);
      ["aria-label", "alt"].forEach((attribute) => {
        const sourceValue = attribute === "aria-label" ? source.ariaLabel : source.alt;
        if (sourceValue === null) return;
        const translated = normalizedLanguage === "en" ? englishAttributes[sourceValue] : undefined;
        element.setAttribute(attribute, translated || sourceValue);
      });
    });

    const pageMetadata = metadata[normalizedLanguage];
    document.title = pageMetadata.title;
    document.querySelector('meta[name="description"]')?.setAttribute("content", pageMetadata.description);
    document.querySelector('meta[property="og:title"]')?.setAttribute("content", pageMetadata.title);
    document.querySelector('meta[property="og:description"]')?.setAttribute("content", pageMetadata.socialDescription);

    const toggle = document.querySelector("#language-toggle");
    if (toggle) {
      const showingEnglish = normalizedLanguage === "en";
      toggle.textContent = showingEnglish ? "中文" : "EN";
      toggle.setAttribute("aria-label", showingEnglish ? "切换到中文" : "Switch to English");
      toggle.title = showingEnglish ? "切换到中文" : "Switch to English";
    }

    try {
      localStorage.setItem("launchease-site-language", normalizedLanguage);
    } catch {
      // Some browsers disable storage for local file previews.
    }

    if (updateAddress) {
      try {
        const url = new URL(window.location.href);
        url.searchParams.set("lang", normalizedLanguage === "en" ? "en" : "zh-Hans");
        window.history.replaceState({}, "", url);
      } catch {
        // The language still switches even if a local preview blocks history updates.
      }
    }
  }

  const requestedLanguage = new URLSearchParams(window.location.search).get("lang");
  let savedLanguage = null;
  try {
    savedLanguage = localStorage.getItem("launchease-site-language");
  } catch {
    // Fall back to the browser language when storage is unavailable.
  }
  const preferredLanguage = navigator.language?.toLowerCase().startsWith("zh") ? "zh-Hans" : "en";
  const initialLanguage = ["en", "zh-Hans"].includes(requestedLanguage)
    ? requestedLanguage
    : (["en", "zh-Hans"].includes(savedLanguage) ? savedLanguage : preferredLanguage);

  applyLanguage(initialLanguage);

  document.querySelector("#language-toggle")?.addEventListener("click", () => {
    applyLanguage(root.lang === "en" ? "zh-Hans" : "en", true);
  });

  function repositoryURL() {
    if (configuredRepository) {
      return `https://github.com/${configuredRepository.replace(/^\/+|\/+$/g, "")}`;
    }

    if (location.hostname.endsWith("github.io")) {
      const owner = location.hostname.split(".")[0];
      const pathParts = location.pathname.split("/").filter(Boolean);
      const repository = pathParts[0] || `${owner}.github.io`;
      return `https://github.com/${owner}/${repository}`;
    }

    return "#";
  }

  const repo = repositoryURL();
  const release = repo === "#"
    ? "../dist/LaunchEase.zip"
    : `${repo}/releases/latest/download/LaunchEase.zip`;

  document.querySelectorAll("[data-repository-link]").forEach((link) => {
    link.href = repo;
  });

  document.querySelectorAll("[data-release-download]").forEach((link) => {
    link.href = release;
  });

  const year = document.querySelector("#year");
  if (year) year.textContent = new Date().getFullYear();

  const revealItems = document.querySelectorAll(".reveal");
  if (!("IntersectionObserver" in window)) {
    revealItems.forEach((item) => item.classList.add("is-visible"));
    return;
  }

  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-visible");
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.14 });

  revealItems.forEach((item) => observer.observe(item));
})();

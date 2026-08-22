(() => {
  const root = document.documentElement;
  const configuredRepository = root.dataset.repository?.trim();

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

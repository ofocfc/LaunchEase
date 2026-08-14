# MacLaunch 宣传页

此目录可以直接通过 GitHub Pages 发布。

1. 在 GitHub 仓库的 `Settings → Pages` 中选择 `Deploy from a branch`。
2. 分支选择 `main`，目录选择 `/docs`。
3. 在 Releases 中发布新版本，并将附件命名为 `MacLaunch.zip`。

页面在 GitHub Pages 环境中会自动根据地址推导 GitHub 仓库，并将下载按钮指向：

```text
https://github.com/用户名/仓库名/releases/latest/download/MacLaunch.zip
```

如果使用自定义域名，请在 `index.html` 的 `<html>` 标签上填写仓库：

```html
<html lang="zh-Hans" data-repository="用户名/仓库名">
```

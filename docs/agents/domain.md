# 领域文档

本仓库采用单上下文布局：术语表位于根目录 `GLOSSARY.md`，架构决策记录（Architecture Decision Record，ADR）位于 `docs/adr/`。

## 探索前读取

- 读取仓库根目录的 `GLOSSARY.md`。
- 读取 `docs/adr/` 中涉及当前处理区域的 ADR。

文件不存在时，静默继续。术语或决策确定后，由 `$domain-modeling` 按需创建。

## 使用术语表词汇

在 issue 标题、重构提案、假设和测试名称中命名领域概念时，使用 `GLOSSARY.md` 定义的术语。保留术语表规定的用词，避开其明确列出的同义词。

概念尚未进入术语表时，先确认项目是否使用这个概念。确认存在术语缺口后，记录给 `$domain-modeling`。

## 处理 ADR 冲突

输出与现有 ADR 矛盾时，指出对应的 ADR 编号，说明矛盾内容和重新讨论的原因。

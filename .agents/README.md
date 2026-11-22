# .agents 폴더 안내

스킬과 에이전트를 Claude Code, Codex, Cursor, Antigravity에서 함께 쓰기 위한 **원본 폴더**임.  
도구별 파일은 `scripts/sync-agents.py`가 이 폴더에서 만들어 냄.

## 무엇을 손으로 고치나

| 경로 | 내용 | 손으로 고치나 |
|------|------|-------------|
| `.agents/agents/{이름}.md` | 에이전트 원본. 프론트매터(name, description, tier, permissions) + 8섹션 본문 | 고침 |
| `.agents/agents/_mapping.toml` | tier, permissions 범주를 도구별 모델 ID와 sandbox 값으로 바꾸는 표 | 고침 |
| `.agents/skills/{이름}/SKILL.md` | 스킬 원본. 프론트매터는 표준 6키만, Claude 확장 키는 `metadata.claude:` 아래 | 고침 |
| `.claude/agents/`, `.claude/skills/` | Claude Code(와 Cursor)용 생성물. 원본을 가리키는 포인터만 담음 | 고치지 않음 |
| `.codex/agents/`, `.codex/config.toml`의 마커 구간 | Codex용 생성물 | 고치지 않음 |

## 고친 뒤 할 일

```bash
python scripts/sync-agents.py          # 생성물 갱신
python scripts/sync-agents.py --check  # 생성물이 최신인지만 검사(다르면 종료 코드 1)
```

- 에이전트 본문은 원본 한 곳에만 둠. 생성물에 본문을 복제하지 않음
- 심볼릭 링크는 쓰지 않음(Windows 개발자 모드 의존을 피함)
- Codex는 `.codex/config.toml`의 `config_file` 등록이 있어야 에이전트를 인식함(2026-09-03 실측)

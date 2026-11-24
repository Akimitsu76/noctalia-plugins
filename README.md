# Noctalia Plugins — Akimitsu76

Fonte de plugins para o [Noctalia](https://noctalia.dev). Este repositório abriga o
plugin de perfis góticos e todos os plugins futuros.

## ✦ Plugins disponíveis

| Plugin | ID | Descrição |
|---|---|---|
| Profiles | `victor/profiles` | Snapshot completo do desktop (config, widgets, layout, molduras, fontes, cores, wallpaper, plugins e assets), com export/import em `.tar.gz` e reinstalação automática na máquina de destino |

![Painel do plugin](docs/panel.png)

## ✦ Instalar como fonte

```bash
noctalia msg plugins source add akimitsu git https://github.com/Akimitsu76/noctalia-plugins
noctalia msg plugins update akimitsu
noctalia msg plugins enable victor/profiles
```

Pronto — **não é preciso rodar `install.sh`**. O painel, o service de molduras e
os dois CLI (`noctalia-profile`, `noctalia-widget-frames`) vêm dentro de
`profiles/bin/` e são materializados junto com o plugin.

Para abrir o painel:

```bash
noctalia msg panel-toggle victor/profiles:profiles
```

### Atalho sugerido (niri)

```kdl
Mod+Shift+P { spawn-sh "noctalia msg panel-toggle victor/profiles:profiles"; }
```

## ✦ Snapshot completo e portátil

`noctalia-profile save <nome>` captura `~/.config/noctalia/` inteiro,
`settings.toml` inteiro (plugins habilitados, fontes, widgets, plugin settings,
barra, tema, wallpaper, shell), dados dos plugins, molduras, plugins locais,
assets referenciados e a revisão de cada fonte git.

No import em outra máquina, o CLI adiciona as fontes que faltam, **pula plugins
já habilitados sem esperar cache `materialized/`**, habilita apenas os ausentes
(espera máxima de 5 s), copia plugins `path` para
`~/.local/share/noctalia/user-plugins/`,
detecta os monitores atuais e **remapeia outputs** (`DP-3` → `eDP-1`, por
exemplo, ajustando resolução, posição dos widgets e wallpaper por monitor), e
**só depois** restaura a configuração. Tudo com backup, `--dry-run` e rollback.

Assim, um perfil salvo com 14 widgets num monitor externo aparece inteiro,
na mesma ordem e layout, em outra máquina que tenha apenas a tela interna.

```bash
noctalia-profile export desktop-principal                    # -> ~/Documents/noctalia-profiles/
noctalia-profile export desktop-principal ~/Downloads/meu.tar.gz
noctalia-profile import ~/Downloads/meu.tar.gz --yes        # instala + aplica
noctalia-profile import ~/Downloads/meu.tar.gz --force --yes # sobrescreve perfil existente
noctalia-profile import ~/Downloads/meu.tar.gz --no-apply   # só instala
noctalia-profile apply desktop-principal --dry-run          # simula
```

Flags: `--yes` confirma fontes git novas sem prompt, `--dry-run` não altera
nada, `--force` substitui um perfil já existente no import e `--no-apply`
apenas instala o perfil na lista sem restaurar.

Saída para painel/service: `PROFILE=`, `PHASE=`, `APPLIED=1`,
`WIDGETS_RESTORED=`, `OUTPUT_REMAP=`, `PLUGINS_INSTALLED=`,
`INSTALLED_PLUGINS=` (compat), `MISSING_PLUGINS=` e `ERROR=<causa>`. Nunca
aparece "comando falhou" sem motivo concreto.

O pacote `.tar.gz` não contém caminhos absolutos do usuário e é validado contra
`..`, symlinks escapando e tamanho excessivo. Manifestos v1 continuam legíveis.
Também dá pelo painel: ícone de download em cada perfil, botão **PROCURAR
ARQUIVO** (seletor zenity) e importação com progresso por fase.

## ✦ Atualizar

```bash
noctalia msg plugins update akimitsu
```

## ✦ Estrutura

Cada plugin vive num diretório cujo nome é a parte depois da `/` do id
(`victor/profiles` → `profiles/`). O `catalog.toml` na raiz indexa todos os plugins
para o Noctalia listar e verificar compatibilidade sem precisar clonar o repo.

```
.
├── catalog.toml          # índice de plugins
├── profiles/             # victor/profiles
│   ├── plugin.toml
│   ├── panel.luau
│   ├── service.luau
│   ├── frames.luau
│   ├── gothic-sticker.luau
│   ├── gothic-label.luau
│   ├── bin/              # CLI embarcados (versionados, executáveis)
│   │   ├── noctalia-profile
│   │   └── noctalia-widget-frames
│   ├── translations/
│   └── README.md
├── bin/                  # cópias/utilitários opcionais para uso manual
├── systemd/              # unidades user para automação das molduras
├── hooks/                # hook opcional do pacman
├── tests/                # simulação de "máquina B" e validações
└── docs/panel.png
```

`install.sh`, `systemd/` e `hooks/` são opcionais e **não** são necessários para
usar o plugin a partir da fonte git. O `__pycache__/` é ignorado pelo git.

## ✦ Adicionar um plugin futuro

1. Crie o diretório com o nome do plugin e um `plugin.toml` válido.
2. Adicione a linha correspondente em `catalog.toml`.
3. Coloque os executáveis que o plugin usa dentro da própria pasta do plugin.
4. Faça commit e push — quem usa a fonte recebe no próximo
   `noctalia msg plugins update akimitsu`.

## ✦ Testes

```bash
python3 -m unittest discover -s tests -v
```

## ✦ Licença

MIT — veja [LICENSE](LICENSE).

<div align="center">

# Nexo

### Seu dinheiro, com clareza.

Controle financeiro pessoal para entender o passado, acompanhar o presente e organizar os próximos compromissos.

![Flutter](https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white)
![Android](https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-0078D4)
![Local first](https://img.shields.io/badge/Dados-locais-00695C)
![Supabase](https://img.shields.io/badge/Sync-Supabase-3ECF8E?logo=supabase&logoColor=white)
[![MIT](https://img.shields.io/badge/Licen%C3%A7a-MIT-blue)](LICENSE)

[Conheça o app](#um-painel-para-o-dia-a-dia) · [Telas](#telas) · [Estado](#estado-do-projeto) · [Executar](#executar-o-projeto) · [Servidor](#servidor-opcional) · [Documentação](#documentação)

</div>

> **In English:** Nexo is a personal finance app for Android and Windows, built with Flutter and Dart.
> Data lives on the device in SQLite and syncs between phone and PC through a Supabase project you own.
> Bank transactions arrive read-only through Open Finance (Pluggy) and land in a review inbox; the app only records on its own what leaves no doubt or what a user rule says, and any automatic entry can be undone.
> An MCP server lets Claude do in the app what the screens do, and its requests show up on an app screen where they can be undone.
> Developed by Daniel Moulaz on top of the MIT-licensed Expensy 1.1.0, with 100+ Dart test files and offline tests for the server. The rest of this README is in Portuguese.

## Um painel para o dia a dia

O Nexo reúne saldo, gastos, cartões, dívidas, investimentos e previsão de caixa em uma experiência compartilhada entre Android e Windows. O foco é reduzir trabalho manual sem perder a precisão dos registros.

- **Hoje:** saldo, quanto ainda dá para gastar no dia e no mês, ritmo ideal do mês, resumo de ontem e da semana, alertas de vencimento e de cobrança.
- **Extrato:** lançamentos por dia, busca, filtros, calendário de gastos e formulário rápido com lançamentos anteriores e atalhos de data.
- **Orçamento e planejamento:** orçamentos por categoria (proporcionais ou cheios no mês em que começam), visão por tipo de gasto (Custos fixos, Conforto, Metas, Prazeres, Conhecimento, Liberdade financeira) em % de uma renda de referência, recorrentes, assinaturas, objetivos e "Mês em revisão".
- **Contas e cartões:** transferências, faturas com a regra do fechamento do banco, pagamento de fatura sem duplicar gasto, empréstimos e dinheiro emprestado.
- **Investimentos:** carteira em reais e em dólar, proventos, importação da B3, comparação com o CDI e prazos de liquidez (D+0, D+2 úteis) para saber quanto dá para resgatar até uma data.
- **Open Finance (opcional):** movimentações dos bancos conectados chegam na caixa "Para revisar". O app resolve sozinho o que não é dúvida (Pix entre contas suas, pagamento de fatura visto dos dois lados, estorno, o que já estava lançado, rendimentos) e mostra o motivo de cada decisão, que pode ser desfeita. Regras do banco dizem o que fazer com um movimento pelo texto dele.
- **Conferir com o banco:** saldo do banco × saldo do Nexo, item a item: o que o banco tem e o Nexo não, o que só o Nexo tem e quanto da diferença isso explica, antes de um ajuste neutro. Limite real e fatura oficial do cartão.
- **Assistente (opcional):** conector MCP com o qual o Claude faz no Nexo tudo o que a pessoa faz nas telas (102 ferramentas), com as mesmas regras do app, inclusive com o app fechado. Cada pedido pode ser desfeito, repetir um pedido não duplica nada e tudo aparece em "Feito pelo Claude" no app. Matriz de cobertura em [docs/mcp-paridade.md](docs/mcp-paridade.md).
- **Seus arquivos:** importação com revisão, exportação CSV/XLSX e backup/restauração.
- **Proteção:** PIN, modo de privacidade que oculta valores e recursos de segurança de cada plataforma.

## Telas

As imagens abaixo são da versão 1.18.0, geradas com **dados fictícios** a partir das telas reais do app (`flutter test tool/readme_screens.dart`). Não representam finanças pessoais reais.

<p align="center">
  <img src="docs/images/nexo-home-mobile.png" width="270" alt="Tela Hoje do Nexo no celular: saldo em contas, quanto posso gastar por dia e atalhos, com dados fictícios" />
  <img src="docs/images/nexo-extrato-mobile.png" width="270" alt="Extrato do Nexo no celular: busca, filtros, totais do mês e lançamentos por dia, com dados fictícios" />
  <img src="docs/images/nexo-orcamento-mobile.png" width="270" alt="Orçamento do Nexo no celular: orçado no mês e metas por tipo de gasto, com dados fictícios" />
</p>

<p align="center">
  <img src="docs/images/nexo-home-desktop.png" width="1100" alt="Painel do Nexo no Windows: saldo, resumo do mês, ritmo de gastos, previsão de caixa e categorias, com dados fictícios" />
</p>

## Precisão antes de automação

- Despesas pendentes não reduzem o saldo atual.
- Transferências, reservas e aportes não viram consumo.
- Compras no cartão entram na fatura; compra feita no dia do fechamento vai para a fatura seguinte, como no banco; pagar a fatura não cria uma segunda despesa.
- Sugestões do Open Finance exigem revisão (ou conciliação segura) antes de virar lançamento. O que o app lança sozinho aparece em "Resolvidas automaticamente", com o motivo, e pode ser desfeito. Nada cria ou apaga dinheiro em silêncio.
- A regra de conciliação é a mesma no app e no assistente: um arquivo de casos roda nos dois lados e o teste falha se um divergir.
- Diferença de saldo com o banco se corrige com **ajuste neutro**, que não conta como gasto nem receita. Um lançamento na categoria de acerto de saldo vira ajuste neutro.
- O banco é copiado antes de cada migração, e um build de desenvolvimento nunca abre os dados reais.
- A fatura do banco é mostrada como conferência; nada é lançado ou pago a partir dela.
- A previsão usa compromissos cadastrados. Não presume salário nem gastos futuros desconhecidos.

## Estado do projeto

Versão de referência: **1.18.0+60** (novembro de 2026, schema 29). Detalhes em [CHANGELOG.md](CHANGELOG.md).

| Área | Situação |
| --- | --- |
| Android | Em uso diário; instalação direta (sem Play Store) |
| Windows | Aplicativo nativo, com SQLite local; homologação manual completa ainda em andamento. O executável não é assinado: o Controle Inteligente de Aplicativos do Windows pode bloquear um build novo |
| Funcionamento offline | Registros e consultas são locais; sincronização, Open Finance e cotações dependem de conexão |
| Sincronização celular ↔ PC | Ativa desde 20/10/2026, por um projeto Supabase próprio, com consentimento, backup e conferência com o servidor |
| Open Finance | Leitura via Meu Pluggy (gratuito para uso pessoal), com conciliação automática do que não é dúvida; sem pagamentos, Pix ou transferências |
| Assistente (Claude/MCP) | Ativo; paridade com as telas desde a 1.13.0. O servidor só enfileira pedidos, um de cada vez; quem grava é o app com as próprias regras. Um teste falha se o app ganhar uma escrita sem ferramenta |
| Telegram/WhatsApp | Proposta documentada; sem bot em produção |

Não há publicação oficial do Nexo na Play Store. O repositório não inclui APKs, bancos pessoais, backups, credenciais de assinatura nem chaves de serviços. Dados no servidor de sincronização **não** têm criptografia de ponta a ponta (decisão consciente, ver [docs/SEGURANCA.md](docs/SEGURANCA.md)).

## Executar o projeto

Use Flutter e Dart compatíveis com `pubspec.yaml`; o ambiente atual usa Flutter **3.47.5**. Confira a instalação com `flutter doctor -v`.

```sh
git clone https://github.com/moul4z/Nexo.git
cd Nexo
flutter pub get
flutter analyze
flutter test --concurrency=1
```

Sem configuração extra o app roda **só local**, sem sincronização nem Open Finance. Para ligar esses recursos a um projeto Supabase seu, crie `tool/nexo_sync.local.json` (ignorado pelo Git) com a URL e a chave **publicável** do projeto, e passe-o no build:

```json
{ "NEXO_SUPABASE_URL": "https://<projeto>.supabase.co", "NEXO_SUPABASE_KEY": "sb_publishable_..." }
```

```sh
flutter run --dart-define-from-file=tool/nexo_sync.local.json
```

O app recusa chaves de serviço (`sb_secret_…`): elas nunca devem ir para o cliente.

**Android:** instale Android SDK e o JDK compatível com o Gradle do projeto, conecte um dispositivo de teste e execute:

```sh
flutter run -d <id-do-dispositivo>
flutter build apk --release --dart-define-from-file=tool/nexo_sync.local.json
```

Sem `--dart-define-from-file` o build sai "sem servidor configurado": funciona só local. Para atualizar uma instalação existente sem perder dados, use `adb install -r` com o **mesmo certificado** de assinatura.

**Windows:** é necessário Visual Studio com **Desktop development with C++** e Windows SDK. Ative o Modo de Desenvolvedor do Windows se o Flutter solicitar suporte a links simbólicos.

Se `flutter pub get` resolver as dependências mas parar por falta de suporte a links, há uma alternativa local em NTFS: execute `./tool/prepare_windows_plugins.ps1` no PowerShell e repita `flutter pub get`. O script prepara os links dos plugins sem alterar o SDK nem as configurações do sistema.

```sh
flutter run -d windows
flutter build windows --release --dart-define-from-file=tool/nexo_sync.local.json
```

O bundle Windows fica em `build/windows/x64/runner/Release/`. Distribua a **pasta inteira**, incluindo DLLs e `data/`, e execute `Nexo.exe`. Para testar sem tocar nos seus dados, use o perfil de teste: `Nexo.exe --test-profile`. Um build que não é de release abre sozinho um perfil de desenvolvimento, separado dos dados reais.

O `Nexo.exe` não é assinado. Com o Controle Inteligente de Aplicativos do Windows ligado, um executável novo pode ser bloqueado ao abrir; isso é decisão do Windows, não um defeito do build.

Credenciais de assinatura ficam apenas na máquina de desenvolvimento. Sem configuração de assinatura própria, o projeto usa a assinatura de depuração como fallback; esse build não equivale a uma distribuição pública assinada.

## Servidor (opcional)

Tudo em `supabase/`, para um projeto Supabase próprio (plano gratuito):

- **Migrations** (`supabase/migrations/`): diário de sincronização, conectores do assistente, Open Finance (sugestões, saldos, faturas). Tabelas em esquemas privados, RLS ligada sem políticas e acesso só por funções que conferem o dono.
- **Edge Functions:**
  - `pluggy-sync`: lê contas, transações e faturas do Meu Pluggy e grava sugestões. Segredos: `PLUGGY_CLIENT_ID`, `PLUGGY_CLIENT_SECRET`, `NEXO_PLUGGY_OWNER`.
  - `nexo-mcp`: servidor MCP do assistente, autenticado por token do conector (só o hash fica no banco). Publicação e ciclo dos pedidos em [supabase/functions/nexo-mcp/README.md](supabase/functions/nexo-mcp/README.md).
  - `market-quotes`: cotações e fechamentos de ações dos EUA; a chave do provedor fica no servidor. Segredo: `FINNHUB_API_KEY`.

Ao atualizar um servidor existente, aplique as migrations em ordem **antes** de publicar as funções: a `pluggy-sync` desta versão depende de `202611180001_reconcile.sql`.

Testes do servidor, sem rede e só com dados fictícios:

```sh
node tool/validate_sync_sql.mjs   # SQL em PGlite
node tool/test_nexo_mcp.mjs       # servidor MCP
node tool/test_pluggy.mjs         # Open Finance
node tool/test_market_quotes.mjs  # cotações
```

O teste `test/mcp_app_parity_test.dart` lê o código do app e do servidor e falha se uma escrita do app não tiver ferramenta do assistente (ou motivo registrado em `lib/sync/app_actions.dart`).

## Arquitetura e dados

- **Flutter/Dart:** interface e regras financeiras compartilhadas entre Android e Windows.
- **SQLite:** armazenamento local; `sqflite` no Android e `sqflite_common_ffi` no Windows. Toda gravação passa por uma operação de domínio atômica.
- **Sincronização:** diário de operações por aparelho, enviado ao Supabase e aplicado nos outros aparelhos; o servidor guarda o diário e um espelho, não aplica regras financeiras.
- **Provider:** estado do aplicativo.
- **Kotlin:** integrações Android (widgets da tela inicial, abertura por atalho, privacidade da janela).
- **TypeScript (Deno):** Edge Functions do Open Finance e do assistente.
- **Testes:** regras contábeis, persistência, sincronização, importação/exportação, segurança, navegação e layouts.

O identificador Android `com.ma.expensy` é preservado para que o app instalado continue o mesmo, com os dados no lugar. O pacote Dart chama-se `nexo` e o banco local, `nexo.db`.

## Documentação

- [Arquitetura da sincronização](docs/NEXO_SYNC_ARCHITECTURE.md)
- [Fronteira de domínio e captura atômica](docs/NEXO_SYNC_DOMAIN_2026_10_20.md)
- [Início da implementação da sincronização](docs/NEXO_SYNC_IMPLEMENTATION.md)
- [Segurança: RLS, segredos e rotação](docs/SEGURANCA.md)
- [Paridade do assistente (MCP) com o app](docs/mcp-paridade.md)
- [Tipografia: fonte, rampa e regras](docs/TIPOGRAFIA.md)
- [Servidor MCP: publicação e ciclo dos pedidos](supabase/functions/nexo-mcp/README.md)
- [Widgets da tela inicial (Android)](HOMESCREEN_WIDGET.md)
- [Histórico de versões](CHANGELOG.md)

Os documentos registram etapas diferentes do desenvolvimento; consulte a data e a versão de cada um. Builds, capturas privadas e bases temporárias não fazem parte do código publicado.

## Desenvolvimento

O Nexo é desenvolvido por [Daniel Moulaz](https://github.com/moul4z) e foi construído a partir de uma base open source sob licença MIT, o [Expensy](https://github.com/mina-android/Expensy), de Mina Android; os créditos estão em [`LICENSE`](LICENSE) e [`NOTICE`](NOTICE).

Contribuições devem manter testes relevantes, compatibilidade dos dados e migrações explícitas quando necessárias. Nunca inclua bancos pessoais, notificações reais, extratos, PINs, tokens, chaves de serviço, keystores ou arquivos de configuração locais em commits ou issues.

Licença [MIT](LICENSE). A fonte Inter, incluída em `assets/fonts/Inter`, segue a [SIL Open Font License](assets/fonts/Inter/OFL.txt).

Portfólio: [moulaz.dev](https://moulaz.dev) · [English](https://moulaz.dev/en/)

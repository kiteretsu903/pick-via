# PickVia

<p align="center">
  <img src="Support/Icons/PickViaArtwork.png" alt="Ícone do aplicativo PickVia" width="128">
</p>

<p align="center"><strong>Pare de abrir links no navegador ou perfil errado.</strong></p>

O macOS pode reutilizar a janela ou o perfil errado do navegador, enquanto todos os
links `mailto:` vão para um único aplicativo de e-mail padrão. O PickVia pergunta
onde abrir cada link, para você escolher o perfil de navegador ou aplicativo de
e-mail instalado de que realmente precisa.

**[Visite o site do PickVia](https://kiteretsu903.github.io/pick-via/)** para ver
capturas de tela, destaques das versões e o [histórico de alterações](https://kiteretsu903.github.io/pick-via/changelog.html).

<p align="center">
  <img src="docs/screenshots/pickvia-browser-chooser-backdrop@2x.png" alt="Seletor de navegadores do PickVia com material translúcido nativo do macOS" width="900">
</p>

## Idiomas

O PickVia v1.5 oferece 80 idiomas no aplicativo e no site, incluindo um seletor de
idioma e layouts da direita para a esquerda, além de 12 idiomas para o README.
Escolha o idioma do aplicativo nos Ajustes ou siga o idioma principal do sistema.
As capturas do produto mostram a interface em inglês.

## Download

**[Baixe o PickVia v1.5 para macOS](https://github.com/kiteretsu903/pick-via/releases/latest)**

O PickVia requer **macOS 14 Sonoma ou posterior** em **Apple Silicon** e processa
links HTTP, HTTPS e `mailto:`.

## O que ele faz

- **Escolha um navegador ou perfil para cada link da web.**
- **Escolha um aplicativo de e-mail instalado para cada link de e-mail.**
- **Processe os links localmente sem salvar um histórico dos links abertos.**

## Seletor de e-mail

<p align="center">
  <img src="docs/screenshots/pickvia-mail-chooser-backdrop@2x.png" alt="Seletor de e-mail do PickVia com material translúcido nativo do macOS" width="900">
</p>

## Configure uma vez

Ative, desative, reordene e busque novamente os destinos de navegador e os
aplicativos de e-mail registrados nos Ajustes.

<p align="center">
  <img src="docs/screenshots/pickvia-settings@2x.png" alt="Ajustes de navegadores do PickVia com perfis de navegador fictícios" width="900">
</p>

## Instalação

1. Baixe e abra `PickVia-v1.5.dmg` na
   [versão do GitHub](https://github.com/kiteretsu903/pick-via/releases/latest).
2. Arraste o **PickVia** para a pasta **Aplicativos** exibida no instalador.
3. Abra o **PickVia** na pasta Aplicativos e siga as etapas de boas-vindas.
4. Escolha **Definir como padrão**. O macOS pede permissão separadamente para
   processar links HTTP e HTTPS.
5. Se quiser, revise seus aplicativos de e-mail instalados e torne o PickVia o
   aplicativo padrão para links `mailto:`, ou escolha **Pular configuração de e-mail**.

### Primeira abertura e Gatekeeper

O PickVia v1.5 é assinado com um certificado Apple Development e não é notarizado. O macOS pode bloquear a
primeira abertura do aplicativo baixado. Se você o baixou da versão do GitHub e
optar por confiar nele:

1. Tente abrir o PickVia uma vez e feche o aviso.
2. Abra **Ajustes do Sistema → Privacidade e Segurança** e role até **Segurança**.
3. Clique em **Abrir Mesmo Assim** e confirme em **Abrir**. O botão fica disponível
   por cerca de uma hora após a tentativa de abertura bloqueada.

Se **Abrir Mesmo Assim** não estiver disponível, confirme que **PickVia.app** está
na pasta Aplicativos, tente abri-lo uma vez para gerar o bloqueio e execute:

```zsh
xattr -dr com.apple.quarantine "/Applications/PickVia.app"
```

A Apple documenta essa exceção ao Gatekeeper e suas implicações de segurança em
[Abrir apps com segurança no Mac](https://support.apple.com/en-asia/102445).

## Navegadores compatíveis

| Navegador / edições | Perfis | Normal | Janela privativa |
|---|---:|---:|---:|
| Safari | Experimental | Sim | Não |
| Safari Technology Preview | Não | Sim | Não |
| DuckDuckGo | Não | Sim | Sim* |
| Chrome Stable / Beta / Dev / Canary, Chromium | Sim | Sim | Sim |
| Edge Stable / Beta / Dev / Canary | Sim | Sim | Sim |
| Brave Stable / Beta / Nightly | Sim | Sim | Sim |
| Vivaldi Stable / Snapshot | Sim | Sim | Sim |
| Firefox Stable / Developer Edition / Nightly | Sim | Sim | Sim |
| Opera, Arc, Orion | Não | Sim | Não |

\* O DuckDuckGo Privativo usa dados isolados e descartáveis em compilações
compatíveis sem sandbox (atualmente a família de versões 1.203.x). Não exige
extensão do DuckDuckGo nem acesso à Acessibilidade. Links normais do DuckDuckGo
não exigem uma versão específica nem assinatura do publicador. Os dados privativos
são limpos após o processo do navegador ser encerrado enquanto o PickVia está em
execução, ou em uma inicialização ou encaminhamento posterior.

Cada edição instalada aparece como um navegador separado, com seu próprio nome e
ícone. Perfis do Firefox associados a outra edição instalada são excluídos da lista
de perfis desse navegador. A associação segue o caminho do aplicativo registrado
pelo Firefox; perfis com metadados ausentes ou não reconhecidos mantêm o comportamento
alternativo existente e podem aparecer em mais de uma edição.

Os destinos Padrão do navegador funcionam sem acesso aos perfis; conceder acesso
adiciona os perfis encontrados. Janelas privativas são opções do navegador: não é
possível combinar um perfil específico com o modo privativo. Opera, Arc e Orion
atualmente oferecem apenas encaminhamento normal para o aplicativo.

A compatibilidade varia conforme a versão do navegador e o estado de inicialização.

## Perfis do Safari (experimental)

Ative os perfis do Safari Stable nos Ajustes de navegadores. Este recurso opcional
exige permissões de Acessibilidade (Controle do Dispositivo e Acesso aos Dados no
macOS 27 ou posterior) e Automação. Cada link abre em uma nova janela do perfil
selecionado. O encaminhamento para perfis do Safari continua experimental.

Para compilações locais, defina `PICKVIA_SIGNING_IDENTITY` com a impressão digital
do seu certificado de assinatura de código, ou salve-a no arquivo ignorado
`.signing-identity`, e execute `scripts/build-app.sh`. Use a mesma identidade nas
recompilações para preservar a identidade do aplicativo nas permissões do macOS.

## Compatibilidade com e-mail

O PickVia processa apenas links `mailto:`, detectando os aplicativos instalados
que o macOS registra para links de e-mail e oferecendo opções por aplicativo —
não por conta, perfil, identidade ou modo de composição. Os Ajustes de e-mail
permitem ativar, desativar, reordenar e buscar novamente os aplicativos registrados;
a configuração de e-mail continua sendo opcional nas boas-vindas.

## Privacidade

- As URLs abertas são processadas localmente; o PickVia nunca as envia, registra
  nem armazena de forma persistente.
- O PickVia não acessa histórico de navegação, cookies, sessões, senhas salvas
  nem conteúdo de páginas.
- O seletor de e-mail não pré-visualiza, registra nem armazena destinatários,
  assuntos, corpos de mensagens ou a solicitação `mailto:` original.

Remova as permissões de acesso aos perfis em **Ajustes de navegadores → Acesso aos perfis → Remover acesso**.

Consulte a [Política de Privacidade](https://kiteretsu903.github.io/pick-via/privacy.html) completa.

## Licença

MIT. Consulte [LICENSE](LICENSE).

# ClipBar

Gerenciador de área de transferência nativo pro macOS. Barra horizontal na base
da tela, pastas coloridas, busca por nome, criptografia em repouso. Local, sem
nuvem, sem conta e sem assinatura paga.

39 MB de RAM, 0 % de CPU em repouso. Zero dependências externas — só frameworks
do sistema.

## Requisitos

- macOS 14 (Sonoma) ou mais novo
- Command Line Tools da Apple (`xcode-select --install`). **Não precisa do Xcode.**

O ClipBar não roda no Windows ou Linux: a interface e as integrações de sistema
usam APIs nativas do macOS (AppKit, Carbon e Keychain).

## Instalar

```bash
git clone https://github.com/murilo-acronn/clipbar-app.git
cd clipbar-app
./scripts/install.sh
```

Compila, monta o `.app` à mão, assina, instala em `/Applications/ClipBar.app` e
abre. Na primeira execução aparece uma tela de boas-vindas com os passos.

> **Máquina com pouca memória:** o SwiftPM usa 10 processos paralelos por padrão.
> Em 16 GB isso já esgotou a memória aqui. Use `JOBS=2 ./scripts/install.sh`.

### Gatekeeper

O app não é notarizado pela Apple — notarização exige uma conta paga de
desenvolvedor. Como você compilou o app na sua própria máquina a partir do
código-fonte, o binário nunca foi baixado da internet e o Gatekeeper não deveria
reclamar. Se reclamar, abra uma vez com **botão direito → Abrir**.

### Autorizar o colar automático

Ajustes do Sistema › Privacidade e Segurança › **Acessibilidade** → adicionar
`/Applications/ClipBar.app`. A tela de boas-vindas tem um botão que leva direto.

É a única permissão que o app pede, e ela serve só pra um propósito: apertar
⌘V por você depois de colocar o item na área de transferência. Sem ela o app
continua útil — o `⏎` copia e você cola com ⌘V.

> **Como saber se funcionou:** aperte `⏎` sobre um campo de texto. Se colar,
> está autorizado.
>
> Não use `--check` como veredito. `AXIsProcessTrusted()` responde pelo processo
> que chama, e o macOS atribui a confiança de Acessibilidade ao *responsible
> process* — rodando o binário pelo terminal, quem responde é o terminal, e o
> resultado vem "não autorizado" mesmo com o app autorizado e colando.

> **Se a permissão cair depois de recompilar:** o macOS amarra a permissão à
> assinatura do app. Veja [Assinatura](#assinatura) — o projeto já traz a
> solução, mas ela precisa de um passo seu.

## Usar

**⌘⌥V** abre a barra.

| Tecla | Ação |
|---|---|
| `←` `→` | navegar entre cards |
| `⇥` · `↑` `↓` | trocar de pasta |
| digitar | buscar **em todas as pastas**, não só na aberta |
| `⏎` | colar no app anterior |
| `⌘1`–`⌘9` | colar direto o card N |
| `⌘R` | dar nome ao card (a busca acha pelo nome) |
| `⌘P` | mover pra outra pasta |
| `⌘N` | criar pasta |
| `⌫` | apagar item · apagar letra da busca |
| `esc` | fechar |

Com o mouse: **clique duplo** cola, **botão direito** abre o mesmo menu de ações,
o **⋯** na barra de abas abre as preferências, e arrastar um card dentro de uma
pasta muda sua ordem. O botão direito numa aba permite renomear ou excluir a
pasta; ao excluir, os itens voltam para a Área de transferência.

Dar nome é o que faz a busca ficar boa: `⌘R` num item, digite `contrato modelo`,
e depois é só digitar "contrato" pra achar — mesmo que o texto do item não tenha
essa palavra.

## Preferências

No **⋯** da barra, no ícone da barra de menus, ou com ⌘, :

- **Atalho** — grave a combinação que quiser. Combinações reservadas do sistema
  são recusadas, e se outro app já usar a combinação o atalho anterior é mantido.
- **Sons** — um ao copiar e outro ao colar, cada um com seu próprio som, ou
  desligados. Os sons próprios do ClipBar são sintetizados por
  `scripts/make-sounds.py`; os 14 sons do macOS também estão na lista.
- **Colar** — liga/desliga o colar automático e mostra o estado real da
  Acessibilidade (esta leitura é confiável: vem do app, não do terminal).
- **Histórico** — quantos itens soltos guardar, e por quantos dias. As duas
  regras avisam antes de apagar, porque não há como desfazer.
- **Apps ignorados** — nada copiado neles entra no histórico.
- **Prévia de links** — opcional e desligada por padrão; busca o título, domínio
  e imagem de capa no site copiado.

## Privacidade

- **Nada sai da máquina por padrão.** A verificação manual de atualização
  consulta o GitHub somente quando você clica no botão. A prévia rica de links é
  desligada por padrão; se você a ligar, cada link novo consulta o respectivo site
  para obter título e imagem. O restante do conteúdo copiado nunca sai daí.
- **Senhas não são capturadas.** Gerenciadores de senha marcam o que copiam com
  `org.nspasteboard.ConcealedType`; o ClipBar respeita essa marca, o que cobre
  qualquer app que se comporte bem, sem precisar de lista de bloqueio. Pra os que
  não se comportam, existe a lista de apps ignorados.
- **Criptografado em repouso.** Conteúdo e imagens são selados com AES-GCM, com
  chave de 256 bits no Keychain, marcada pra nunca sincronizar.

  Isso protege o banco vazando pra onde não devia — backup, pasta sincronizada,
  cópia pra um pendrive. **Não** protege contra código malicioso rodando como
  você, que pode pedir a chave ao Keychain ou simplesmente ler o clipboard.

**O que fica guardado, e onde:** `~/Library/Application Support/ClipBar/` —
`clipbar.sqlite` e `blobs/`. A chave fica no Keychain, serviço `io.local.clipbar`.
Pra apagar tudo, remova essa pasta e a entrada do Keychain.

**Não existe relatório de erro nem telemetria.** A verificação de atualização é
manual, não baixa nem instala nada sozinha — mostra a versão nova e abre a página
do release, e quem atualiza é você, com `git pull && ./scripts/install.sh`.
Um atualizador que troca o próprio app em execução é o código mais perigoso de um
projeto assim, e este aqui não é notarizado nem tem como verificar o que baixou.

## Migrar do Paste

Se você usa o [Paste](https://pasteapp.io/), dá pra trazer as pastas:

```bash
/Applications/ClipBar.app/Contents/MacOS/ClipBar --import-paste --dry-run  # simula
/Applications/ClipBar.app/Contents/MacOS/ClipBar --import-paste            # importa
/Applications/ClipBar.app/Contents/MacOS/ClipBar --verify                  # confere
```

Traz as pastas com nomes e cores e tudo que está dentro delas — texto e imagens.
O histórico solto fica pra trás de propósito: é rotatividade do dia a dia.

**Não apaga nem altera nada do Paste.** Mantenha o Paste instalado por uns dias
antes de desinstalar; ele é a sua cópia de segurança até você confiar no ClipBar.

## Assinatura

Por padrão os scripts assinam ad-hoc, e isso tem um custo: o macOS amarra a
permissão de Acessibilidade e o ACL do Keychain ao *designated requirement* do
binário, que na assinatura ad-hoc **é o hash do código**. Cada recompilação muda
o hash, então cada recompilação revoga a permissão e pede a senha do Keychain de
novo.

Se você vai só instalar e usar, ignore isto. Se vai recompilar com frequência,
crie uma identidade estável uma vez:

```bash
# 1. Gerar um certificado de code signing autoassinado
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=ClipBar Local Signing" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# 2. Empacotar com os algoritmos que o Security framework da Apple aceita
#    (o padrão do OpenSSL 3 é recusado com "MAC verification failed")
openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12 -passout pass:temp \
  -name "ClipBar Local Signing" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

# 3. Importar e confiar (pede sua senha)
security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign cert.pem

rm key.pem cert.p12   # a chave privada agora vive no Keychain
```

O `scripts/signing.sh` acha a identidade sozinho. Se ela não estiver no keychain,
os scripts avisam em stderr e caem pra ad-hoc em vez de falhar. Pra usar outro
nome: `CODESIGN_ID="Minha Identidade" ./scripts/install.sh`.

Depois disso o *designated requirement* passa a apontar pro certificado em vez do
hash do código, e a Acessibilidade sobrevive às recompilações. Confira com:

```bash
codesign -d -r- /Applications/ClipBar.app
```

## Diagnóstico

```bash
ClipBar --check          # permissões (leia a ressalva sobre falso negativo acima)
ClipBar --verify         # integridade dos dados
ClipBar --find "termo"   # depurar a busca sem imprimir conteúdo
ClipBar --self-test      # testa banco/criptografia num diretório temporário
```

Nenhum deles imprime o conteúdo dos itens.

## Licença

MIT — veja [LICENSE](LICENSE).

Os sons em `Resources/Sounds/` são gerados por `scripts/make-sounds.py` e
seguem a mesma licença do projeto.

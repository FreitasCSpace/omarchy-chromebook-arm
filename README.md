# Omarchy para Chromebooks Qualcomm (pen USB / cartão SD)

Imagem do Omarchy 4 (aarch64) que arranca pelo bootloader do próprio Chromebook (depthcharge), sem tocar no ChromeOS do disco interno. No ecrã de arranque escolhe-se entre ChromeOS (Ctrl+D) e Omarchy na pen (Ctrl+U).

Modelos alvo: Snapdragon 7c / 7c Gen 2 ("trogdor": Lenovo Duet 5 / IdeaPad 5 CB, Acer Spin 513, HP Chromebook 11a/x2, Samsung Galaxy Chromebook Go, etc.) e 7c+ Gen 3 ("herobrine"). O kernel leva os device trees de todos e o firmware escolhe o do modelo.

## Como funciona

- Base: Arch Linux ARM + kernel `linux-aarch64` (já traz os drivers do SC7180/SC7280), com os repositórios aarch64 oficiais do Omarchy, no canal **rc** (`pkgs.omarchy.org/rc/aarch64`). O `omarchy` 4.0.6 do canal stable para aarch64 é anterior ao detetor de plataforma, ao `omarchy-pkg-defaults` e à configuração de hardware adiada, que este build usa; o 4.5.0rc1 já os tem. Usa `OMARCHY_CHANNEL=stable` quando o stable os tiver.
- O `btrfs-overlayfs` (hook do mkinitcpio para arrancar snapshots pelo Limine) é retirado por `zz-omarchy-chromebook.conf`: sem Limine não existe nem tem o que arrancar. Os snapshots do snapper continuam a ser criados.
- `chromebook/devkeys/` traz as chaves de teste públicas do `vboot_reference` da Google (as mesmas que qualquer Chromebook em modo de programador aceita), porque o `vboot-utils` do Arch Linux ARM não as inclui.
- O Omarchy é instalado pela mesma sequência do instalador oficial (pacotes iniciais, `omarchy-pkg-defaults aarch64-qualcomm`, `omarchy-apply-system --defer-provisioning`), e a configuração do hardware fica adiada para o primeiro arranque no Chromebook (manifesto de imagem do Omarchy).
- Arranque: em vez do Limine/UEFI, `omarchy-chromebook-kernel` empacota kernel + initramfs + device trees num FIT, assina-o com as chaves de programador do vboot e grava-o na partição `KERN-A`. Um post-hook do mkinitcpio (`/etc/initcpio/post/90-omarchy-chromebook`) repete isto a cada atualização do kernel ou do initramfs.
- No primeiro arranque: a partição root cresce até ao tamanho total da pen, o hardware é configurado, o initramfs é refeito para este modelo e o assistente do Omarchy pede o nome de utilizador e a palavra-passe.

Disposição da imagem: `p1 KERN-A` (256 MiB, kernel assinado) e `p2 root` (btrfs com os subvolumes `@`, `@home`, `@log` e `@pkg`, como no instalador oficial). A imagem não é encriptada.

## Construir

Num sistema aarch64 (por exemplo, o Linux do próprio Chromebook):

```bash
sudo apt install vboot-kernel-utils cgpt u-boot-tools arch-install-scripts libarchive-tools btrfs-progs gdisk lz4 device-tree-compiler
git clone --depth 1 https://github.com/basecamp/omarchy.git upstream
git clone --depth 1 https://github.com/omacom/omarchy-iso.git iso
sudo ./fetch-chromeos-firmware.sh   # firmware do modem/Wi-Fi, tirado da imagem de recuperação oficial do ChromeOS
sudo ./build.sh            # -> out/omarchy-chromebook.img (14 GiB, cabe numa pen de 16 GB)
```

O Wi-Fi da trogdor (WCN3990) corre no subsistema do modem, que arranca imagens assinadas pela Google (`qcom/sc7180-trogdor/modem*/{mba,qdsp6sw}.mbn`). O linux-firmware não as traz e não podem ser redistribuídas, por isso o repositório inclui o script e não os ficheiros. O script descarrega a imagem de recuperação "strongbad" (homestar, coachz, wormdingler, quackingstick) e copia só esse diretório. Para outros modelos, passa-lhe o URL certo do `recovery2.json`.

Os pacotes ficam em cache em `dl/pkg`, por isso um segundo build não volta a descarregar nada. `sudo ./build.sh --resume` reaproveita uma imagem cuja instalação de pacotes já terminou e corre só a configuração seguinte. Serve para iterar sobre um passo que falhou; uma imagem para distribuir faz-se sempre sem ele.

## Instalar e arrancar

> **Atenção:** ativar o modo de programador faz um **powerwash**, que apaga tudo o que está no Chromebook, **incluindo o Linux (Crostini) e os ficheiros dele**. Faz cópia de segurança antes. O ChromeOS em si continua a funcionar.

1. Grava a imagem numa pen USB ou cartão SD com 16 GB ou mais. Faz isto antes do powerwash se estás a construir no Crostini: partilha a pen com o Linux e corre `sudo dd if=out/omarchy-chromebook.img of=/dev/sdX bs=4M status=progress conv=fsync`. Em alternativa, usa o balenaEtcher noutro computador.
2. Ativa o modo de programador: desliga o Chromebook, carrega em Esc + Atualizar + Power, e depois Ctrl+D e confirma. O Chromebook apaga-se e reinicia.
3. No ChromeOS, abre o crosh (Ctrl+Alt+T), escreve `shell` e corre:
   ```bash
   sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0
   ```
4. Liga a pen, reinicia e, no ecrã "OS verification is OFF", carrega em **Ctrl+U**. Em firmware mais recente, escolhe "Boot from external disk".
5. O primeiro arranque demora alguns minutos: cresce a partição, configura o hardware e refaz o kernel. Depois aparece o assistente do Omarchy para criares o utilizador.

Para voltar ao ChromeOS, basta reiniciar sem a pen ou carregar em Ctrl+D.

## Estado

| Componente | Estado |
| --- | --- |
| Build da imagem | funciona num Chromebook trogdor (Crostini aarch64); assinatura vboot e FIT verificados com `futility` e `dumpimage` |
| Arranque por depthcharge, ecrã, teclado, Wi-Fi, áudio | **por testar no hardware**: os drivers e o firmware estão no kernel e no `linux-firmware-qcom`, mas ainda não arrancou num Chromebook real |
| Dual boot no disco interno | não suportado (ver abaixo) |

Risco conhecido: o kernel assinado do primeiro arranque tem cerca de 53 MiB (kernel 21 MiB + initramfs genérico 23 MiB + 59 device trees), porque o initramfs só pode ser feito à medida do modelo no próprio Chromebook. Não confirmei o limite do depthcharge da trogdor para o tamanho do kernel. Se o Ctrl+U der um bipe e não arrancar, o primeiro passo é reduzir o initramfs do build.

## Dual boot no disco interno (futuro)

Tecnicamente possível: encolher a partição `STATE` do ChromeOS, criar uma `KERN-C` e uma root a seguir, e apontar o `omarchy-chromebook-kernel --partition` para a `KERN-C`. Há dois riscos: um powerwash recria a tabela de partições, e as atualizações do ChromeOS mexem nas prioridades das `KERN-A`/`KERN-B`. Só vale a pena depois de a pen arrancar bem.

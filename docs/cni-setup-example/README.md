# CNI → Firecracker: przykład bez SDK i Kubernetes

Wyobraź sobie, że chcesz uruchomić jedną microVM. Najpierw przygotowujesz jej
„gniazdko sieciowe” na hoście, potem podpinasz je do Firecrackera, a na końcu
ustawiasz adres wewnątrz VM. CNI pomaga w pierwszej części:

| Element | Co robi |
|---|---|
| `ptp` | Tworzy parę veth, trasy i NAT do wyjścia przez hosta. |
| `host-local` | Wywoływany przez `ptp`; rezerwuje IP w lokalnej puli. |
| `firewall` | Dodaje reguły przepuszczające ruch VM przez hosta. |
| `tc-redirect-tap` | Tworzy TAP i przekierowuje pakiety między nim a veth. |
| My | Tworzymy namespace, wywołujemy pluginy, konfigurujemy VM i sprzątamy. |

Plugin to lokalny program: **JSON na stdin, wynik JSON na stdout** oraz parametry
w zmiennych `CNI_*`. Nie wysyłamy do niego HTTP. Po konfiguracji plugin kończy
pracę; pakiety obsługuje kernel. Dopiero API Firecrackera wywołujemy przez HTTP.

## 1. Przygotuj hosta

Przykład jest dla jednej VM, IPv4 i Ubuntu 24.04 z KVM. Polecenia wykonuj
z katalogu głównego repozytorium na **hoście Firecrackera**, nie w microVM.
Najpierw uruchom `./install.sh`: instaluje też potrzebne pluginy w `/opt/cni/bin`.
Go jest potrzebne tylko do zbudowania adaptera; ten przykład nie używa SDK Go.

W terminalu A otwórz Bash jako root. Tak uruchamiamy ten ręczny przykład labowy
(TAP będzie należał do roota):

```bash
sudo bash
export CNI_PATH=/opt/cni/bin
export CNI_CONTAINERID=vm-001
export CNI_NETNS=/run/netns/vm-001
export CNI_IFNAME=veth0
export CNI_ARGS=
export FC_SOCKET=/tmp/firecracker-vm-001.socket
STATE_DIR="$(mktemp -d /tmp/firecracker-cni-vm-001.XXXXXX)"
echo "Wyniki i konfiguracje: $STATE_DIR"

for plugin in ptp host-local firewall tc-redirect-tap; do
  CNI_COMMAND=VERSION "$CNI_PATH/$plugin"
done

cp docs/cni-setup-example/network.conflist "$STATE_DIR/network.conflist"
printf 'null\n' > "$STATE_DIR/result.json"
ip netns add vm-001
ip -n vm-001 link set lo up
```

Używaj świeżego namespace i wolnej puli `10.200.1.0/24`. `STATE_DIR` przechowuje
wejścia oraz wyniki aż do sprzątania zasobów; nie kasuj go wcześniej. Konfigurację czytamy
bezpośrednio z pliku — nie trzeba jej rejestrować w `/etc/cni/net.d`.

## 2. Wywołaj bezpośrednio `ADD` po kolei

Cała lista jest w [network.conflist](./network.conflist). Pojedyncza binarka
otrzymuje tylko własny obiekt z listy, wspólne `name` i `cniVersion`, a od drugiego
pluginu także `prevResult`. `jq` tylko składa te JSON-y.

**`ptp` → `host-local`:** powstają veth, przydział IP, routing i masquerade.
`ptp` sam włącza wymagane przekazywanie pakietów IPv4 na hoście.

```bash
export CNI_COMMAND=ADD
jq '.plugins[0] + {name, cniVersion}' \
  "$STATE_DIR/network.conflist" > "$STATE_DIR/ptp.json"
"$CNI_PATH/ptp" < "$STATE_DIR/ptp.json" > "$STATE_DIR/ptp-result.json" &&
  cp "$STATE_DIR/ptp-result.json" "$STATE_DIR/result.json"
```

**`firewall`:** dostaje wynik `ptp` i dodaje reguły przekazywania pakietów.

```bash
jq --slurpfile prev "$STATE_DIR/result.json" \
  '.plugins[1] + {name, cniVersion, prevResult: $prev[0]}' \
  "$STATE_DIR/network.conflist" > "$STATE_DIR/firewall.json"
"$CNI_PATH/firewall" < "$STATE_DIR/firewall.json" > "$STATE_DIR/firewall-result.json" &&
  cp "$STATE_DIR/firewall-result.json" "$STATE_DIR/result.json"
```

**`tc-redirect-tap`:** powstaje TAP i przekierowanie ruchu veth ↔ TAP.

```bash
jq --slurpfile prev "$STATE_DIR/result.json" \
  '.plugins[2] + {name, cniVersion, prevResult: $prev[0]}' \
  "$STATE_DIR/network.conflist" > "$STATE_DIR/tap.json"
"$CNI_PATH/tc-redirect-tap" < "$STATE_DIR/tap.json" > "$STATE_DIR/tap-result.json" &&
  cp "$STATE_DIR/tap-result.json" "$STATE_DIR/result.json"

cat "$STATE_DIR/tap.json"     # dokładne dane wejściowe ostatniego ADD
jq . "$STATE_DIR/result.json" # odpowiedź całego łańcucha
```

Po błędzie **zatrzymaj się i przejdź do sprzątania**, zamiast wywoływać kolejne
`ADD`. `result.json` zachowuje ostatni poprawny wynik. To ręczny przykład:
nie ma automatycznego cofania zmian. Reguły `firewall` pozwalają na ruch, ale nie
stanowią pełnej polityki izolacji sandboxów.

## 3. Uruchom proces Firecrackera w namespace

W **terminalu B**, również z katalogu repozytorium:

```bash
sudo ip netns exec vm-001 ./firecracker --api-sock /tmp/firecracker-vm-001.socket
```

Zostaw ten terminal otwarty. TAP istnieje wewnątrz `vm-001`, więc Firecracker
musi działać w tej samej przestrzeni sieciowej. Nie usuwaj socketu działającej VM;
jeżeli został po poprzedniej, najpierw upewnij się, że tamten proces się zakończył.

## 4. Przekaż wynik do Firecrackera i guesta

Wróć do **terminala A**. Najpierw skonfiguruj CPU, pamięć, kernel i dysk:

```bash
./init-firecracker "$FC_SOCKET"
```

W wyniku adaptera są dwa wpisy związane z TAP: hostowy ma `sandbox` równy ścieżce
namespace, a opis interfejsu guesta ma `sandbox: "vm-001"`. Wybieramy ten drugi:
jego `name` wskazuje TAP, a `mac` jest adresem, który ma otrzymać **guest**.

```bash
jq -e --arg vm "$CNI_CONTAINERID" '
  (.interfaces | to_entries[] | select(.value.sandbox == $vm)) as $nic
  | .ips[] | select(.interface == $nic.key)
  | {tap: $nic.value.name, mac: $nic.value.mac, address, gateway}
' "$STATE_DIR/result.json" > "$STATE_DIR/vm.json"
jq . "$STATE_DIR/vm.json"
```

Firecracker nie przyjmuje konfiguracji CNI bezpośrednio. Do jego API przekazujemy
**nazwę istniejącego TAP i MAC guesta**:

```bash
jq '{iface_id: "eth0", host_dev_name: .tap, guest_mac: .mac}' \
  "$STATE_DIR/vm.json" > "$STATE_DIR/firecracker-network.json"
cat "$STATE_DIR/firecracker-network.json"

curl --fail-with-body --silent --show-error --unix-socket "$FC_SOCKET" \
  -X PUT http://localhost/network-interfaces/eth0 \
  -H 'Content-Type: application/json' \
  --data-binary @"$STATE_DIR/firecracker-network.json"
```

**IP i brama należą do konfiguracji Linuksa w VM**, nie do tego endpointu API.
Przekażemy je przez parametr kernela `ip=`. Maska poniżej odpowiada `/24`
z naszego pliku CNI; po zmianie podsieci trzeba dopasować również maskę.

```bash
GUEST_CIDR="$(jq -er '.address' "$STATE_DIR/vm.json")"
GUEST_IP="${GUEST_CIDR%/*}"
GUEST_GATEWAY="$(jq -er '.gateway' "$STATE_DIR/vm.json")"
KERNEL="$(pwd)/$(ls vmlinux-* | sort -V | tail -1)"
BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off ip=$GUEST_IP::$GUEST_GATEWAY:255.255.255.0::eth0:off"

jq -n --arg kernel "$KERNEL" --arg args "$BOOT_ARGS" \
  '{kernel_image_path: $kernel, boot_args: $args}' > "$STATE_DIR/boot-source.json"
curl --fail-with-body --silent --show-error --unix-socket "$FC_SOCKET" \
  -X PUT http://localhost/boot-source \
  -H 'Content-Type: application/json' \
  --data-binary @"$STATE_DIR/boot-source.json"

./start-firecracker.sh "$FC_SOCKET"
```

Drugie `PUT /boot-source` uzupełnia konfigurację z `init-firecracker`, jeszcze
przed startem VM. Kernel musi obsługiwać `CONFIG_IP_PNP`; jeśli po bootowaniu
`eth0` nie ma adresu, ustaw w konsoli guesta `ip addr add <address> dev eth0`
i `ip route replace default via <gateway>`, używając wartości z `vm.json`.

## 5. Sprawdź połączenie i posprzątaj

W konsoli **guesta** w terminalu B, jako root:

```bash
ip link set eth0 up mtu 1400
ip -4 addr show eth0
ip route
printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf
ping -c 3 10.200.1.1
ping -c 3 1.1.1.1
getent hosts example.com
```

MTU i DNS ustawiamy jawnie zgodnie z `network.conflist`; sam JSON CNI nie zmienia
pliku `/etc/resolv.conf` guesta. Te ustawienia są przykładowe i nietrwałe.
Z hosta w terminalu A możesz też wykonać `ping -c 3 "$GUEST_IP"`.

Na koniec wykonaj `poweroff` **w gueście** i poczekaj, aż proces Firecrackera
w terminalu B się zakończy. W terminalu A usuń sieć w odwrotnej kolejności:

```bash
export CNI_COMMAND=DEL
for index in 2 1 0; do
  jq --argjson index "$index" --slurpfile prev "$STATE_DIR/result.json" '
    .plugins[$index] + {name, cniVersion}
    + (if $prev[0] == null then {} else {prevResult: $prev[0]} end)
  ' "$STATE_DIR/network.conflist" > "$STATE_DIR/delete.json"
  plugin="$(jq -r '.type' "$STATE_DIR/delete.json")"
  "$CNI_PATH/$plugin" < "$STATE_DIR/delete.json"
done
```

Każde `DEL` dostaje ostatni zapisany wynik i tę samą tożsamość przydziału.
`ptp` wywołuje też `host-local DEL`, zwalniając adres. Sprawdź błędy wszystkich
trzech wywołań; w razie błędu zachowaj `STATE_DIR` i ponów sprzątanie. Po sukcesie:

```bash
ip netns del vm-001
rm -f -- "$FC_SOCKET"
rm -rf -- "$STATE_DIR"
```

Przy częściowym błędzie `ADD` wykonaj te same `DEL`. Usunięcie namespace sprząta
też ewentualny TAP, którego plugin nie zdążył dopisać do wyniku. Nie usuwaj całego
`/var/lib/cni`: zawiera rezerwacje innych przydziałów. `ptp` pozostawia globalny
mechanizm przekazywania pakietów włączony; mogą korzystać z niego inne sieci.

Źródła: [kontrakt CNI](https://www.cni.dev/docs/spec/),
[ptp](https://www.cni.dev/plugins/current/main/ptp/),
[adapter TAP](https://github.com/awslabs/tc-redirect-tap),
[Firecracker: sieć](https://github.com/firecracker-microvm/firecracker/blob/main/docs/network-setup.md).

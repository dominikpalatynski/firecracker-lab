# Firecracker Lab

Proste środowisko do eksperymentowania z microVM Firecrackera w Google Cloud.

## 1. Zaloguj się do Google Cloud

```bash
gcloud auth login
```

Wybierz projekt:

```bash
export PROJECT_ID="identyfikator-twojego-projektu"

gcloud config set project "$PROJECT_ID"
```

Włącz API Compute Engine:

```bash
gcloud services enable compute.googleapis.com
```

## 2. Utwórz maszynę wirtualną

Używamy maszyny typu N2 z włączoną wirtualizacją zagnieżdżoną. Dzięki temu
Firecracker może korzystać z KVM i uruchamiać własne microVM wewnątrz tej maszyny.

```bash
export VM_NAME="firecracker-lab"
export ZONE="europe-west4-a"

gcloud compute instances create "$VM_NAME" \
  --zone="$ZONE" \
  --machine-type=n2-standard-2 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --enable-nested-virtualization
```

## 3. Połącz się przez SSH

```bash
gcloud compute ssh "$VM_NAME" \
  --zone="$ZONE"
```

Sprawdź, czy KVM jest dostępne:

```bash
ls -l /dev/kvm
```

Wynik powinien wyglądać podobnie do:

```text
crw-rw---- 1 root kvm ... /dev/kvm
```

Jeśli Twój użytkownik nie ma dostępu do KVM, dodaj go do grupy `kvm`:

```bash
sudo usermod -aG kvm $USER
```

Następnie rozłącz sesję SSH i połącz się ponownie.

Sprawdź uprawnienia:

```bash
test -r /dev/kvm && test -w /dev/kvm && echo "KVM OK"
```

## 4. Zainstaluj Firecrackera, jądro, system plików i pluginy CNI

Sklonuj to repozytorium, przejdź do jego katalogu i uruchom:

```bash
chmod +x install.sh
./install.sh
```

Skrypt pobiera i przygotowuje:

- Firecrackera,
- jądro Linuksa dla systemu gościa,
- główny system plików Ubuntu (`rootfs`),
- referencyjne pluginy CNI: `ptp`, `host-local` i `firewall` (v1.9.1),
- adapter `tc-redirect-tap`, budowany za pomocą Go z ustalonej wersji źródeł.

Binarki CNI trafiają do `/opt/cni/bin`. Skrypt instaluje też `jq`, `iproute2`
i `iptables`, potrzebne do wykonania przykładu konfiguracji sieci.

## 5. Uruchom API Firecrackera

Jeśli chcesz uruchomić VM **z siecią**, zamiast kroków 5–7 wykonaj
[przewodnik konfiguracji CNI](./docs/cni-setup-example/README.md).
Pokazuje on przygotowanie sieci i uruchomienie Firecrackera w przestrzeni
sieciowej (`namespace`), w której znajduje się jego TAP.
Poniższe polecenia uruchamiają VM bez interfejsu sieciowego.

Firecracker udostępnia API HTTP przez gniazdo Unix (socket).

Uruchom proces Firecrackera:

```bash
export FC_SOCKET="/tmp/firecracker.socket"

rm -f "$FC_SOCKET"

./firecracker --api-sock "$FC_SOCKET"
```

Zostaw ten terminal otwarty.

Otwórz drugą sesję SSH:

```bash
gcloud compute ssh "$VM_NAME" \
  --zone="$ZONE"
```

## 6. Uruchom microVM

W katalogu repozytorium wykonaj:

```bash
chmod +x init-firecracker start-firecracker.sh

./init-firecracker /tmp/firecracker.socket
./start-firecracker.sh /tmp/firecracker.socket
```

`init-firecracker` konfiguruje:

- 1 vCPU,
- 512 MiB RAM,
- jądro Linuksa,
- główny system plików.

Ten skrypt przygotowuje VM, ale nie konfiguruje sieci ani nie uruchamia systemu
gościa. `start-firecracker.sh` wysyła wyłącznie akcję `InstanceStart`.
Interfejs sieciowy i parametry startowe gościa skonfiguruj między tymi dwoma
poleceniami, jeśli uruchamiasz wariant z siecią.

Komunikaty uruchamianego systemu gościa pojawią się w terminalu, w którym działa
proces Firecrackera.

## 7. Konfiguracja sieci

W [przykładzie konfiguracji CNI](./docs/cni-setup-example/README.md) znajdziesz
bezpośrednie wywołania pluginów, wejściowe i wynikowe JSON-y, żądania do API
Firecrackera, ustawienie IP gościa, sprawdzenie łączności i sprzątanie zasobów.
Przykład używa `ptp` + `host-local` + `firewall` + `tc-redirect-tap`, bez Kubernetes
i SDK Go.

Porównanie własnego modułu sieciowego z CNI i plan pomiarów znajdziesz w
[dokumencie o networkingu hosta](./docs/HOST-NETWORKING-BENCHMARK.md) (po angielsku).

Wykonaj ten przykład od początku, z nowym procesem Firecrackera. Proces
uruchomiony wcześniej w domyślnej przestrzeni sieciowej nie zobaczy TAP
znajdującego się w przestrzeni `vm-001` z przykładu.

## 8. Zatrzymaj microVM

Wykonaj na hoście:

```bash
export FC_SOCKET="/tmp/firecracker.socket"
./delete-firecracker.sh
```

Jeśli nie ustawisz `FC_SOCKET`, skrypt użyje `/tmp/firecracker.socket`.
Wysyła on `SendCtrlAltDel` i usuwa socket natychmiast po udanym wywołaniu API.
Jeśli API odrzuci żądanie, socket pozostanie. Aby obsłużyć Ctrl-Alt-Del, system
gościa musi działać — nie może być wstrzymany.


## Usuń maszynę w Google Cloud

Po zakończeniu eksperymentów usuń maszynę:

```bash
gcloud compute instances delete "$VM_NAME" \
  --zone="$ZONE"
```

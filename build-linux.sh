#!/bin/bash
# Compila o prefixo Linux dentro de uma imagem manylinux.
# O chamador monta este repositório em /work e define IMAGE_GLIBC (2.17 ou 2.28).
set -euo pipefail

PG_VERSION=17.9
VECTOR_VERSION=0.8.7
OPENSSL_VERSION=3.0.16
GLIBC_FLOOR="${IMAGE_GLIBC:-2.17}"
PREFIX=/opt/atlas-pg
SRC=/tmp/src
JOBS=2

log() { echo "==> $*"; }

enable_compiler() {
    shopt -s nullglob
    local tools=(/opt/rh/gcc-toolset-*/enable /opt/rh/devtoolset-*/enable)
    if [[ ${#tools[@]} -eq 0 ]]; then
        command -v gcc >/dev/null || { echo "a imagem não tem gcc" >&2; exit 1; }
        log "compilador padrão $(gcc --version | head -1)"
        return
    fi
    local sorted
    mapfile -t sorted < <(printf '%s\n' "${tools[@]}" | sort -V)
    set +u
    # shellcheck disable=SC1090
    source "${sorted[-1]}"
    set -u
    log "compilador $(gcc --version | head -1)"
}

need_elf() {
    local magic
    magic=$(od -An -t x1 -N 4 "$1" 2>/dev/null | tr -d ' \n')
    [[ "$magic" == "7f454c46" ]]
}

fetch() {
    local url=$1 dest=$2
    if [[ -f "$dest" ]]; then
        log "já existe $(basename "$dest")"
        return
    fi
    log "baixando $(basename "$dest")"
    curl -fsSL --retry 3 -o "$dest" "$url"
}

log "glibc alvo ${GLIBC_FLOOR}; jobs ${JOBS}"
mkdir -p /work/.cache/linux-log
trap 'cp -a /tmp/*.log /tmp/src/postgresql/config.log /work/.cache/linux-log/ 2>/dev/null || true' EXIT
free -m || true
yum_ok=0
for _try in 1 2 3; do
    if yum install -y zlib-devel bzip2 perl perl-IPC-Cmd python3 flex bison; then
        yum_ok=1
        break
    fi
    log "yum falhou, nova tentativa"
    sleep 5
done
[[ "$yum_ok" -eq 1 ]] || { echo "yum não instalou as dependências" >&2; exit 1; }
enable_compiler

mkdir -p "$SRC" "$PREFIX" /work/dist /work/.cache/src
cd "$SRC"
TARBALL=/work/.cache/src

fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
    "$TARBALL/openssl.tar.gz"
fetch "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2" \
    "$TARBALL/postgresql.tar.bz2"
fetch "https://github.com/pgvector/pgvector/archive/refs/tags/v${VECTOR_VERSION}.tar.gz" \
    "$TARBALL/pgvector.tar.gz"
fetch "https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0.tar.bz2" \
    "$TARBALL/patchelf.tar.bz2"

log "patchelf"
rm -rf "$SRC/patchelf"
mkdir -p "$SRC/patchelf"
tar -xjf "$TARBALL/patchelf.tar.bz2" -C "$SRC/patchelf" --strip-components=1
(
    cd "$SRC/patchelf"
    ./configure --prefix=/tmp/patchelf-root >/tmp/patchelf-configure.log
    make -j"$JOBS" >/tmp/patchelf-make.log
    make install >/tmp/patchelf-install.log
)
export PATH="/tmp/patchelf-root/bin:${PATH}"

log "OpenSSL ${OPENSSL_VERSION}"
rm -rf "$SRC/openssl" /tmp/ossl
mkdir -p "$SRC/openssl"
tar -xzf "$TARBALL/openssl.tar.gz" -C "$SRC/openssl" --strip-components=1
(
    cd "$SRC/openssl"
    ./Configure linux-x86_64 shared \
        --prefix=/tmp/ossl --libdir=lib --openssldir=/tmp/ossl \
        -Wl,-rpath,'$ORIGIN' >/tmp/openssl-configure.log
    make -j"$JOBS" >/tmp/openssl-make.log
    make install_sw >/tmp/openssl-install.log
)
mkdir -p "$PREFIX/lib"
cp -a /tmp/ossl/lib/libssl.so* /tmp/ossl/lib/libcrypto.so* "$PREFIX/lib/"
cp -a /lib64/libz.so.1* "$PREFIX/lib/"
gcc_s=$(gcc -print-file-name=libgcc_s.so.1)
if [[ -f "$gcc_s" ]]; then
    cp -a "$gcc_s" "$PREFIX/lib/"
fi

log "PostgreSQL ${PG_VERSION}"
rm -rf "$SRC/postgresql"
mkdir -p "$SRC/postgresql"
tar -xjf "$TARBALL/postgresql.tar.bz2" -C "$SRC/postgresql" --strip-components=1
(
    cd "$SRC/postgresql"
    # RPATH absoluto só para o teste do configure achar o OpenSSL.
    # O patchelf no fim troca pelo $ORIGIN, senão o prefixo não muda de pasta.
    export LDFLAGS="-Wl,-rpath,/tmp/ossl/lib -L/tmp/ossl/lib -L${PREFIX}/lib"
    export LD_LIBRARY_PATH="/tmp/ossl/lib:${PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export CPPFLAGS="-I/tmp/ossl/include"
    export LIBRARY_PATH="/tmp/ossl/lib:${PREFIX}/lib"
    ./configure \
        --prefix="$PREFIX" \
        --disable-rpath \
        --with-openssl \
        --with-includes=/tmp/ossl/include \
        --with-libraries="/tmp/ossl/lib ${PREFIX}/lib" \
        --without-icu \
        --without-readline \
        --without-ldap \
        --without-gssapi \
        --without-pam \
        --without-libxml \
        --without-libxslt \
        --without-systemd \
        --without-llvm \
        >/tmp/pg-configure.log
    make -j"$JOBS" >/tmp/pg-make.log
    make install >/tmp/pg-install.log
    make -C contrib -j"$JOBS" >/tmp/pg-contrib.log
    make -C contrib install >/tmp/pg-contrib-install.log
)

log "pgvector ${VECTOR_VERSION}"
rm -rf "$SRC/pgvector"
mkdir -p "$SRC/pgvector"
tar -xzf "$TARBALL/pgvector.tar.gz" -C "$SRC/pgvector" --strip-components=1
(
    cd "$SRC/pgvector"
    make PG_CONFIG="$PREFIX/bin/pg_config" OPTFLAGS="-O2 -Wl,-rpath,\$ORIGIN" -j"$JOBS"
    make PG_CONFIG="$PREFIX/bin/pg_config" install
)

rm -rf "$PREFIX/include" "$PREFIX/share/man" "$PREFIX/share/doc" "$PREFIX/lib/pkgconfig" \
    "$PREFIX/lib/postgresql/pgxs"
find "$PREFIX" -name '*.a' -delete

log "ajustando RPATH"
while IFS= read -r -d '' file; do
    if ! need_elf "$file"; then
        continue
    fi
    dyn=$(readelf -d "$file" 2>/dev/null || true)
    # Conversões de encoding não têm seção dinâmica. libz e libgcc só pedem a glibc.
    if [[ "$dyn" != *NEEDED* && "$dyn" != *RPATH* && "$dyn" != *RUNPATH* ]]; then
        continue
    fi
    outside=0
    if [[ "$dyn" == *"/tmp/"* || "$dyn" == *"/opt/"* ]]; then
        outside=1
    fi
    if [[ "$outside" -eq 0 ]]; then
        while IFS= read -r lib; do
            case "$lib" in
                libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libresolv.so*|ld-linux*) ;;
                "") ;;
                *) outside=1 ;;
            esac
        done < <(sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' <<<"$dyn")
    fi
    if [[ "$outside" -ne 1 ]]; then
        continue
    fi
    case "$file" in
        "$PREFIX"/bin/*) patchelf --set-rpath '$ORIGIN/../lib' "$file" ;;
        "$PREFIX"/lib/postgresql/*.so) patchelf --set-rpath '$ORIGIN/..' "$file" ;;
        *) patchelf --set-rpath '$ORIGIN' "$file" ;;
    esac
done < <(find "$PREFIX/bin" "$PREFIX/lib" -type f -print0)

log "conferindo glibc e bibliotecas"
python3 - <<PY
import os, subprocess, sys
prefix = "${PREFIX}"
floor = tuple(int(x) for x in "${GLIBC_FLOOR}".split("."))
allowed = (
    "libc.so", "libm.so", "libdl.so", "libpthread.so", "librt.so",
    "libresolv.so", "libnss_", "ld-linux", "linux-vdso",
)
bad = []
glibc_bad = []
for root, dirs, files in os.walk(prefix):
    for name in files:
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as fh:
                if fh.read(4) != b"\x7fELF":
                    continue
        except OSError:
            continue
        dumped = subprocess.Popen(["objdump", "-T", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        out, _err = dumped.communicate()
        out = out or ""
        for token in out.split():
            if not token.startswith("GLIBC_"):
                continue
            rest = token.split("_", 1)[1]
            if not rest or not rest[0].isdigit():
                continue
            try:
                nums = tuple(int(x) for x in rest.split("."))
            except ValueError:
                continue
            if nums > floor:
                glibc_bad.append("%s: %s" % (path, token))
        ldd = subprocess.Popen(["ldd", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        ldd_out, ldd_err = ldd.communicate()
        ldd_out = ldd_out or ""
        ldd_text = ldd_out + (ldd_err or "")
        if "not a dynamic executable" in ldd_text or "statically linked" in ldd_text:
            continue
        if ldd.returncode != 0 and "=>" not in ldd_out:
            bad.append("ldd falhou %s %s" % (path, ldd_text.strip()))
            continue
        for line in ldd_out.splitlines():
            line = line.strip()
            if "=>" not in line:
                if not line:
                    continue
                soname = line.split()[0]
                if soname.startswith("linux-vdso") or "/" in soname:
                    continue
                if not soname.startswith(allowed):
                    bad.append("%s: %s" % (path, line))
                continue
            soname, rest = line.split("=>", 1)
            soname = soname.strip()
            rest = rest.strip()
            if rest.startswith("not found"):
                bad.append("%s: %s" % (path, line))
                continue
            target = rest.split()[0]
            if target.startswith(prefix + "/"):
                continue
            if soname.startswith(allowed):
                continue
            bad.append("%s: %s" % (path, line))
if glibc_bad or bad:
    print("GLIBC acima do piso:")
    print("\\n".join(glibc_bad[:40]))
    print("bibliotecas de fora do prefixo:")
    print("\\n".join(bad[:40]))
    sys.exit(1)
print("glibc e ldd ok")
PY

required=(
    bin/postgres
    lib/postgresql/vector.so
    lib/postgresql/unaccent.so
    lib/postgresql/postgres_fdw.so
    lib/postgresql/pgcrypto.so
    lib/postgresql/pg_trgm.so
    lib/postgresql/btree_gist.so
    share/postgresql/tsearch_data/portuguese.stop
)
for rel in "${required[@]}"; do
    if [[ ! -e "$PREFIX/$rel" ]]; then
        echo "falta $rel" >&2
        exit 1
    fi
done
# postgres_fdw 1.1, pg_trgm 1.6 e btree_gist 1.7 não têm um SQL único:
# o default_version do controle chega lá por scripts de upgrade.
check_ext() {
    local name=$1 version=$2
    local control="$PREFIX/share/postgresql/extension/${name}.control"
    if [[ ! -f "$control" ]]; then
        echo "falta $control" >&2
        exit 1
    fi
    if ! grep -q "default_version = '${version}'" "$control"; then
        echo "$name não está em ${version}" >&2
        cat "$control" >&2
        exit 1
    fi
}
check_ext vector 0.8.7
check_ext unaccent 1.1
check_ext postgres_fdw 1.1
check_ext pgcrypto 1.3
check_ext pg_trgm 1.6
check_ext btree_gist 1.7

ver=$("$PREFIX/bin/postgres" -V)
echo "$ver"
[[ "$ver" == *" ${PG_VERSION} "* || "$ver" == *"${PG_VERSION}" ]] || {
    echo "versão inesperada: $ver" >&2
    exit 1
}

cp "$SRC/postgresql/COPYRIGHT" "$PREFIX/COPYRIGHT"
cp /tmp/ossl/LICENSE.txt "$PREFIX/OPENSSL-LICENSE.txt" 2>/dev/null || cp "$SRC/openssl/LICENSE.txt" "$PREFIX/OPENSSL-LICENSE.txt"
cat >> "$PREFIX/COPYRIGHT" <<EOF

pgvector ${VECTOR_VERSION} is distributed under the PostgreSQL License.
OpenSSL ${OPENSSL_VERSION} is distributed under the Apache License 2.0.
See OPENSSL-LICENSE.txt in this directory.
EOF
cat > "$PREFIX/VERSION.txt" <<EOF
postgresql=${PG_VERSION}
pgvector=${VECTOR_VERSION}
openssl=${OPENSSL_VERSION}
glibc_max=${GLIBC_FLOOR}
EOF

rm -f /work/dist/atlas-pg-linux-x64.tar.gz
tar -C "$PREFIX" -czf /work/dist/atlas-pg-linux-x64.tar.gz .
log "BUILD_OK $(du -h /work/dist/atlas-pg-linux-x64.tar.gz | awk '{print $1}')"

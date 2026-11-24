#!/bin/bash
# ISPC compiler, needed by the halcyon device of the ANARI SDK.
source /scripts/common.sh
version="$1"

mkdir -p "${ISPC_ROOT}"
wget -q -O /tmp/ispc.tar.gz \
    "https://github.com/ispc/ispc/releases/download/v${version}/ispc-v${version}-linux.tar.gz"
tar -xzf /tmp/ispc.tar.gz -C "${ISPC_ROOT}" --strip-components=1
rm /tmp/ispc.tar.gz
"${ISPC_ROOT}/bin/ispc" --version

# libanari links Threads::Threads with THREADS_PREFER_PTHREAD_FLAG. Before glibc 2.34 this adds
# -pthread to the compile options of every language, and ISPC rejects it : remove it for ISPC.
cat > "${ISPC_ROOT}/bin/ispc-nopthread" <<EOF
#!/bin/bash
args=()
for a in "\$@"; do [ "\$a" = "-pthread" ] || args+=("\$a"); done
exec "${ISPC_ROOT}/bin/ispc" "\${args[@]}"
EOF
chmod +x "${ISPC_ROOT}/bin/ispc-nopthread"

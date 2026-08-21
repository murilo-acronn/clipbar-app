# Resolves the code signing identity, shared by build.sh and install.sh.
#
# Why not ad-hoc: macOS binds the Accessibility permission and the Keychain ACL
# to the binary's designated requirement. Ad-hoc signing puts the *code hash* in
# that requirement, and the hash changes on every compile — so every build
# silently revoked Accessibility and re-prompted for the Keychain password.
# A stable self-signed certificate puts the *certificate* in the requirement
# instead, which survives rebuilds. Created 21/08/2026; to recreate it, see the
# "Assinatura" section in README.md.

SIGN_ID="${CODESIGN_ID:-ClipBar Local Signing}"

if [ "$SIGN_ID" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
    echo "aviso: identidade '$SIGN_ID' não está no keychain — caindo pra ad-hoc." >&2
    echo "       o app vai funcionar, mas a Acessibilidade será revogada neste build." >&2
    SIGN_ID="-"
fi

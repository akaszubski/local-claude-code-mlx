# Sourced helper. Exposes log_size <path>; echoes integer byte count, 0 if missing.
# Cross-platform: BSD stat (Darwin) vs GNU stat (Linux).

if [[ -z "${_LOG_OFFSET_STAT_FLAG:-}" ]]; then
    case "$(uname -s)" in
        Darwin) _LOG_OFFSET_STAT_FLAG="-f%z" ;;
        *)      _LOG_OFFSET_STAT_FLAG="-c%s" ;;
    esac
fi

log_size() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo 0
        return 0
    fi
    stat "$_LOG_OFFSET_STAT_FLAG" "$path" 2>/dev/null || echo 0
}

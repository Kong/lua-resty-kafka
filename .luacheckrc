std             = "ngx_lua"
unused_args     = false
redefined       = false
max_line_length = false


globals = {
    "ngx.worker.pids",
}


not_globals = {
    "string.len",
    "table.getn",
}


ignore = {
    "6.", -- ignore whitespace warnings
}

files["spec/**/*.lua"] = {
    std = "ngx_lua+busted",
}

files["**/*_test.lua"] = {
    std = "ngx_lua+busted",
}

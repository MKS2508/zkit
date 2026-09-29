//! Tests del ErrorSpace ampliado: completitud en los dos sentidos, nombres
//! TypeScript con prefijo/caso/override (el caso de styx: tabla manual de
//! `SourceError` en `local_file.zig` contra `SourceErrorCode` de
//! `@styx/source-sdk`), `codeOfAny`/`nameOf`, y compatibilidad BYTE A BYTE de
//! la salida por defecto con la de `master` (el fichero generado de hyperdiff
//! no puede cambiar por esta ampliación).
const std = @import("std");
const testing = std.testing;
const errors = @import("errors.zig");

const IoErrors = error{ FILE_NOT_FOUND, PERMISSION_DENIED, INVALID_HANDLE };
const HashErrors = error{ INVALID_UTF8, BUFFER_OVERFLOW };
const MultiSpace = errors.ErrorSpace(IoErrors || HashErrors, &.{
    .{ .name = "io", .base = 1000, .entries = &.{
        .{ .tag = "FILE_NOT_FOUND", .message = "File not found" },
        .{ .tag = "PERMISSION_DENIED", .message = "Permission denied" },
        .{ .tag = "INVALID_HANDLE", .message = "Invalid handle" },
    } },
    .{ .name = "hash", .base = 2000, .entries = &.{
        .{ .tag = "INVALID_UTF8", .message = "Invalid UTF-8 sequence" },
        .{ .tag = "BUFFER_OVERFLOW", .message = "Buffer overflow" },
    } },
});

/// Salida de `master` (a985961) para el mismo espacio, capturada antes del cambio.
const golden_master =
    \\export type ErrorCode =
    \\  | "FILE_NOT_FOUND"
    \\  | "PERMISSION_DENIED"
    \\  | "INVALID_HANDLE"
    \\  | "INVALID_UTF8"
    \\  | "BUFFER_OVERFLOW"
    \\;
    \\
    \\export const NAME_TO_CODE = {
    \\  FILE_NOT_FOUND: 1000,
    \\  PERMISSION_DENIED: 1001,
    \\  INVALID_HANDLE: 1002,
    \\  INVALID_UTF8: 2000,
    \\  BUFFER_OVERFLOW: 2001,
    \\} as const;
    \\
    \\export const CODE_TO_NAME: Record<number, ErrorCode> = {
    \\  1000: "FILE_NOT_FOUND",
    \\  1001: "PERMISSION_DENIED",
    \\  1002: "INVALID_HANDLE",
    \\  2000: "INVALID_UTF8",
    \\  2001: "BUFFER_OVERFLOW",
    \\};
    \\
    \\export const CODE_TO_MESSAGE: Record<number, string> = {
    \\  1000: "File not found",
    \\  1001: "Permission denied",
    \\  1002: "Invalid handle",
    \\  2000: "Invalid UTF-8 sequence",
    \\  2001: "Buffer overflow",
    \\};
    \\
    \\export const DOMAIN_OF: Record<number, string> = {
    \\  1000: "io",
    \\  1001: "io",
    \\  1002: "io",
    \\  2000: "hash",
    \\  2001: "hash",
    \\};
;

test "salida por defecto idéntica byte a byte a master" {
    try testing.expectEqualStrings(golden_master ++ "\n", MultiSpace.emitTypeScript());
}

/// Forma de styx: variantes snake_case en Zig, códigos `SOURCE_*` en TS.
const SourceError = error{
    unknown,
    file_not_found,
    permission_denied,
    io_error,
    cancelled,
    deadline_exceeded,
    invalid_offset,
    path_traversal,
    range_too_large,
    not_regular_file,
};

const SourceSpace = errors.ErrorSpaceWith(SourceError, &.{
    .{ .name = "source", .base = 3000, .entries = &.{
        .{ .tag = "unknown", .message = "Error desconocido" },
        .{ .tag = "file_not_found", .message = "Fichero no encontrado" },
        .{ .tag = "permission_denied", .message = "Permiso denegado", .ts_name = "SOURCE_FILE_PERMISSION_DENIED" },
        .{ .tag = "io_error", .message = "Error de E/S" },
        .{ .tag = "cancelled", .message = "Operación cancelada" },
        .{ .tag = "deadline_exceeded", .message = "Deadline excedido" },
        .{ .tag = "invalid_offset", .message = "Offset inválido" },
        .{ .tag = "path_traversal", .message = "Ruta fuera de la raíz" },
        .{ .tag = "range_too_large", .message = "Rango demasiado grande" },
        .{ .tag = "not_regular_file", .message = "No es un fichero regular", .ts_name = "SOURCE_FILE_NOT_REGULAR" },
    } },
}, .{ .ts_type_name = "SourceErrorCode", .ts_const_prefix = "SOURCE_ERROR_", .ts_prefix = "SOURCE_", .ts_case = .upper });

test "styx: nombres TS con prefijo, mayúsculas y overrides" {
    const ts = SourceSpace.emitTypeScript();
    try testing.expect(std.mem.indexOf(u8, ts, "export type SourceErrorCode =\n") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "  | \"SOURCE_FILE_NOT_FOUND\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "  | \"SOURCE_PATH_TRAVERSAL\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "  | \"SOURCE_RANGE_TOO_LARGE\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "  | \"SOURCE_FILE_PERMISSION_DENIED\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "  | \"SOURCE_FILE_NOT_REGULAR\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "export const SOURCE_ERROR_NAME_TO_CODE = {\n") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "export const SOURCE_ERROR_CODE_TO_NAME: Record<number, SourceErrorCode> = {\n") != null);
    try testing.expect(std.mem.indexOf(u8, ts, "  3007: \"SOURCE_PATH_TRAVERSAL\",\n") != null);
    // El nombre Zig no se filtra al TS.
    try testing.expect(std.mem.indexOf(u8, ts, "path_traversal") == null);
}

test "styx: codeOf/errorOf/nameOf/codeOfAny" {
    try testing.expectEqual(@as(u16, 3007), SourceSpace.codeOf(error.path_traversal));
    try testing.expectEqual(@as(u16, 3008), SourceSpace.codeOf(error.range_too_large));
    try testing.expectEqual(error.range_too_large, SourceSpace.errorOf(3008).?);
    try testing.expectEqualStrings("SOURCE_RANGE_TOO_LARGE", SourceSpace.nameOf(3008).?);
    try testing.expectEqualStrings("SOURCE_FILE_PERMISSION_DENIED", SourceSpace.nameOf(3002).?);
    try testing.expect(SourceSpace.nameOf(3999) == null);
    // Un error de un conjunto más ancho (lo que llega por `anyerror` a la
    // frontera IPC): se traduce si es del espacio, `null` si no.
    const wide: anyerror = error.cancelled;
    try testing.expectEqual(@as(?u16, 3004), SourceSpace.codeOfAny(wide));
    try testing.expectEqual(@as(?u16, null), SourceSpace.codeOfAny(error.OutOfMemory));
    // Todos los códigos hacen ida y vuelta.
    for (3000..3010) |c| {
        const e = SourceSpace.errorOf(@intCast(c)).?;
        try testing.expectEqual(@as(u16, @intCast(c)), SourceSpace.codeOf(e));
    }
}

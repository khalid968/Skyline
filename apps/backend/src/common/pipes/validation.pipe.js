import { ValidationPipe, BadRequestException } from '@nestjs/common';

// Strict request validation, applied globally.
//
// - whitelist + forbidNonWhitelisted: a request carrying a field the DTO does
//   not declare is rejected, not silently trimmed. That closes mass-assignment
//   holes (a client smuggling `role: "admin"` into a body) instead of hoping
//   nobody tries.
// - transform: payloads become real DTO instances, so validators run on the
//   right types.
export function createValidationPipe() {
  return new ValidationPipe({
    whitelist: true,
    forbidNonWhitelisted: true,
    transform: true,
    stopAtFirstError: false,
    // Report which fields are wrong, but never echo the offending values back.
    validationError: { target: false, value: false },
    exceptionFactory: (errors) =>
      new BadRequestException(
        errors.flatMap((e) =>
          Object.values(
            e.constraints || { invalid: `${e.property} is invalid` },
          ),
        ),
      ),
  });
}

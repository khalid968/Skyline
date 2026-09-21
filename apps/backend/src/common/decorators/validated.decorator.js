// In TypeScript, Nest learns which DTO class a @Body() parameter should be
// validated against from compiler-emitted type metadata. This project is plain
// JavaScript, so there is none, and without it the global ValidationPipe has no
// class to check the payload against and silently validates NOTHING.
//
// This supplies that metadata explicitly. Use it with @Bind:
//
//   @Post()
//   @Bind(Body())
//   @Validated(CreateThingDto)
//   create(dto) { ... }
//
// One DTO per parameter, in parameter order. A route that takes a body and
// omits @Validated is unvalidated; test/app/route-inventory.e2e-spec.js checks
// that no body-taking route is missing it.
export const Validated =
  (...dtos) =>
  (target, key, descriptor) => {
    Reflect.defineMetadata('design:paramtypes', dtos, target, key);
    return descriptor;
  };

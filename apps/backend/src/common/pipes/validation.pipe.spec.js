// Doubles as a de-risking check: DTOs use class-validator PROPERTY decorators,
// and this project compiles plain JS through Babel with legacy decorators. If
// that combination silently did nothing, validation would be off across the
// whole API without anyone noticing. These tests prove it is on.
import { IsString, IsInt, Min, Length, IsOptional } from 'class-validator';
import { createValidationPipe } from './validation.pipe';

class CreateThingDto {
  @IsString()
  @Length(3, 20)
  name;

  @IsInt()
  @Min(1)
  count;

  @IsOptional()
  @IsString()
  note;
}

const run = (payload) =>
  createValidationPipe().transform(payload, {
    type: 'body',
    metatype: CreateThingDto,
  });

describe('global validation pipe', () => {
  it('passes a valid payload and returns a real DTO instance', async () => {
    const out = await run({ name: 'widget', count: 3 });
    expect(out).toBeInstanceOf(CreateThingDto);
    expect(out.name).toBe('widget');
  });

  it('rejects a value that breaks a constraint', async () => {
    await expect(run({ name: 'ab', count: 3 })).rejects.toMatchObject({
      status: 400,
    });
  });

  it('rejects a wrong type', async () => {
    await expect(run({ name: 'widget', count: 'three' })).rejects.toMatchObject(
      { status: 400 },
    );
  });

  it('rejects a missing required field', async () => {
    await expect(run({ name: 'widget' })).rejects.toMatchObject({
      status: 400,
    });
  });

  it('REJECTS an undeclared field instead of quietly dropping it (mass assignment)', async () => {
    await expect(
      run({ name: 'widget', count: 3, role: 'admin' }),
    ).rejects.toMatchObject({
      status: 400,
    });
  });

  it('accepts an optional field being absent', async () => {
    await expect(run({ name: 'widget', count: 3 })).resolves.toBeDefined();
  });

  it('reports which fields are wrong without echoing the submitted values', async () => {
    let body;
    try {
      await run({ name: 'x', count: 3 });
    } catch (e) {
      body = JSON.stringify(e.getResponse());
    }
    expect(body).toMatch(/name/);
    expect(body).not.toContain('"x"');
  });
});

import { Controller, Get, Bind, Req, Res, Dependencies } from '@nestjs/common';
import { CallsService } from './calls.service';

// Member route (device sessions only): no path parameters, nothing to look up.
@Controller('calls')
@Dependencies(CallsService)
export class CallsController {
  constructor(calls) {
    this.calls = calls;
  }

  @Get('turn')
  @Bind(Req(), Res({ passthrough: true }))
  turn(req, res) {
    return this.calls.credentials(req.account, res);
  }
}

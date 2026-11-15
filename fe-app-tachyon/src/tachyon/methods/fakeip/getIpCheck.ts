import {
  BROWSER_DIRECT_IP_TRACE_URL,
  IP_CHECK_ENDPOINT,
} from '../../../constants';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

interface IGetIpCheckResponse {
  fakeip: boolean;
  IP: string;
}

export async function getIpCheck(): Promise<
  IBaseApiResponse<IGetIpCheckResponse>
> {
  // Generate direct client trace probe before reading backend direct IP verification.
  void fetch(BROWSER_DIRECT_IP_TRACE_URL, {
    mode: 'no-cors',
    cache: 'no-store',
  }).catch(() => undefined);

  return createBaseApiRequest<IGetIpCheckResponse>(
    () =>
      fetch(IP_CHECK_ENDPOINT, {
        method: 'GET',
        credentials: 'same-origin',
        headers: { Accept: 'application/json' },
      }),
    {
      operationName: 'getIpCheck',
      timeoutMs: 6000,
    },
  );
}

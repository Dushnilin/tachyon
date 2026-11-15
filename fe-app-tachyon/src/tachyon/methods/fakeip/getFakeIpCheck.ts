import {
  BROWSER_PUBLIC_IP_TRACE_URL,
  FAKEIP_CHECK_ENDPOINT,
} from '../../../constants';
import { createBaseApiRequest, IBaseApiResponse } from '../../api';

interface IGetFakeIpCheckResponse {
  fakeip: boolean;
  IP: string;
}

export async function getFakeIpCheck(): Promise<
  IBaseApiResponse<IGetFakeIpCheckResponse>
> {
  // Generate lightweight client traffic before reading backend FakeIP & proxy exit state.
  void fetch(BROWSER_PUBLIC_IP_TRACE_URL, {
    mode: 'no-cors',
    cache: 'no-store',
  }).catch(() => undefined);

  return createBaseApiRequest<IGetFakeIpCheckResponse>(
    () =>
      fetch(FAKEIP_CHECK_ENDPOINT, {
        method: 'GET',
        credentials: 'same-origin',
        headers: { Accept: 'application/json' },
      }),
    {
      operationName: 'getFakeIpCheck',
      timeoutMs: 6000,
    },
  );
}

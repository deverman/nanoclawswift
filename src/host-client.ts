import http from 'http';

import { HOST_SOCKET_PATH, HOST_REQUEST_TIMEOUT_MS } from './config.js';

export interface HostInboundEvent {
  channel: string;
  chat_jid: string;
  sender: string;
  sender_name: string;
  content: string;
  timestamp: string;
  message_id: string;
  is_direct: boolean;
}

export interface OutboundMessage {
  id: string;
  chat_jid: string;
  text: string;
  created_at: string;
}

interface OutboundClaimResponse {
  messages: OutboundMessage[];
}

interface OutboundAckResponse {
  acked_count: number;
}

interface HealthResponse {
  ok: boolean;
  active_group_sessions: number;
  queue_depth: number;
  db_status: string;
  response_p50_ms?: number;
  response_p95_ms?: number;
  timeout_rate?: number;
  retry_rate?: number;
  completed_jobs?: number;
}

function request<T>(
  method: 'GET' | 'POST',
  path: string,
  payload?: unknown
): Promise<T> {
  return new Promise((resolve, reject) => {
    const body = payload ? Buffer.from(JSON.stringify(payload)) : null;
    const req = http.request(
      {
        socketPath: HOST_SOCKET_PATH,
        path,
        method,
        headers: body
          ? {
            'content-type': 'application/json',
            'content-length': body.length
          }
          : undefined,
        timeout: HOST_REQUEST_TIMEOUT_MS
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
        res.on('end', () => {
          const raw = Buffer.concat(chunks).toString('utf8').trim();
          if (res.statusCode && res.statusCode >= 400) {
            reject(new Error(`Host request failed (${res.statusCode}): ${raw || '(empty body)'}`));
            return;
          }

          if (!raw) {
            resolve({} as T);
            return;
          }

          try {
            resolve(JSON.parse(raw) as T);
          } catch (error) {
            reject(new Error(`Invalid JSON response from host: ${String(error)} body=${raw.slice(0, 300)}`));
          }
        });
      }
    );

    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy(new Error(`Host request timed out after ${HOST_REQUEST_TIMEOUT_MS}ms`));
    });

    if (body) req.write(body);
    req.end();
  });
}

export async function postInboundEvent(event: HostInboundEvent): Promise<void> {
  await request('POST', '/v1/events/inbound', event);
}

export async function claimOutbound(channel: string, maxCount = 10): Promise<OutboundMessage[]> {
  const response = await request<OutboundClaimResponse>('POST', '/v1/outbound/claim', {
    channel,
    max_count: maxCount
  });
  return response.messages || [];
}

export async function ackOutbound(messageIds: string[]): Promise<number> {
  if (messageIds.length === 0) return 0;
  const response = await request<OutboundAckResponse>('POST', '/v1/outbound/ack', {
    message_ids: messageIds
  });
  return response.acked_count ?? 0;
}

export async function hostHealth(): Promise<HealthResponse> {
  return request<HealthResponse>('GET', '/v1/health');
}

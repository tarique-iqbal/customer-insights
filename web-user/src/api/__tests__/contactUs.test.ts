import { describe, it, expect, vi, beforeEach } from 'vitest';
import { sendContactMessage, ContactFormValues } from '@/api/contactUs';
import http from '@/api/http';

vi.mock('@/api/http', () => ({
  default: {
    post: vi.fn(),
  },
}));

const mockedPost = http.post as unknown as ReturnType<typeof vi.fn>;

describe('sendContactMessage', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('should send contact message successfully', async () => {
    const formData: ContactFormValues = {
      name: 'John Doe',
      email: 'john@example.com',
      message: 'Hello!',
    };

    const mockResponse = { success: true, message: 'Sent!' };

    mockedPost.mockResolvedValueOnce({ data: mockResponse });

    const result = await sendContactMessage(formData);

    expect(mockedPost).toHaveBeenCalledWith('/api/contact', formData, { signal: undefined });
    expect(result).toEqual(mockResponse);
  });

  it('should throw AbortError when request is canceled', async () => {
    const formData: ContactFormValues = {
      name: 'Jane',
      email: 'jane@example.com',
      message: 'Test',
    };

    const abortError: any = new Error('canceled');
    abortError.name = 'CanceledError';
    abortError.code = 'ERR_CANCELED';

    mockedPost.mockRejectedValueOnce(abortError);

    const promise = sendContactMessage(formData);

    await expect(promise).rejects.toThrowError(DOMException);
    await expect(promise).rejects.toThrowError(/Request aborted/);
  });

  it('should throw Error with backend message when API fails', async () => {
    const formData: ContactFormValues = {
      name: 'Fail',
      email: 'fail@example.com',
      message: 'Oops',
    };

    const apiError = {
      response: { data: { error: 'Internal server error' } },
      message: 'Request failed',
    };

    mockedPost.mockRejectedValueOnce(apiError);

    await expect(sendContactMessage(formData)).rejects.toThrow(
      'Internal server error'
    );
  });

  it('should throw generic error when no backend message', async () => {
    const formData: ContactFormValues = {
      name: 'Fail Again',
      email: 'fail2@example.com',
      message: 'Oops',
    };

    const apiError = new Error('Network error');

    mockedPost.mockRejectedValueOnce(apiError);

    await expect(sendContactMessage(formData)).rejects.toThrow(
      'Failed to send message: Network error'
    );
  });
});

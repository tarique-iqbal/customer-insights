import http from '@/api/http';

export interface ContactFormValues {
  name: string;
  email: string;
  message: string;
}

export const sendContactMessage = async (
  data: ContactFormValues,
  signal?: AbortSignal
): Promise<{ success: boolean; message: string }> => {
  try {
    const response = await http.post('/api/contact', data, { signal });
    return response.data;
  } catch (error) {
    const err = error as {
      name?: string;
      code?: string;
      response?: { data?: { message?: string } };
      message?: string;
    };
    if (err.name === 'CanceledError' || err.code === 'ERR_CANCELED') {
      throw new DOMException('Request aborted', 'AbortError');
    }
    throw new Error(
      err.response?.data?.message || `Failed to send message: ${err.message}`
    );
  }
};

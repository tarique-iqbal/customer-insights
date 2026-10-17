import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import ContactUs from '@/pages/ContactUs';
import { vi } from 'vitest';

vi.mock('@/api/contactUs', () => ({
  sendContactMessage: vi.fn(),
}));

import { sendContactMessage } from '@/api/contactUs';

// Backend requires at least 80 characters (Message.php) — long enough to
// satisfy that, short enough to read easily in a test failure diff.
const VALID_MESSAGE =
  'Hello! I would like to get in touch regarding your services and learn more about what you offer.';

describe('ContactUs Page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders form fields correctly', () => {
    render(<ContactUs />);

    expect(screen.getByLabelText(/name/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/email/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/message/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /send/i })).toBeInTheDocument();
  });

  it('shows validation errors when submitting empty form', async () => {
    render(<ContactUs />);

    fireEvent.click(screen.getByRole('button', { name: /send/i }));

    expect(
      await screen.findByText(/name must be at least 2 characters long/i)
    ).toBeInTheDocument();
    expect(await screen.findByText(/invalid email format/i)).toBeInTheDocument();
    expect(
      await screen.findByText(/message must be at least 80 characters long/i)
    ).toBeInTheDocument();
  });

  it('rejects a name containing digits or special characters', async () => {
    render(<ContactUs />);

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'John3' },
    });
    fireEvent.change(screen.getByLabelText(/email/i), {
      target: { value: 'john@example.com' },
    });
    fireEvent.change(screen.getByLabelText(/message/i), {
      target: { value: VALID_MESSAGE },
    });

    fireEvent.click(screen.getByRole('button', { name: /send/i }));

    expect(
      await screen.findByText(/special characters and numbers are not allowed/i)
    ).toBeInTheDocument();
    expect(sendContactMessage).not.toHaveBeenCalled();
  });

  it('rejects a message shorter than 80 characters', async () => {
    render(<ContactUs />);

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'John Doe' },
    });
    fireEvent.change(screen.getByLabelText(/email/i), {
      target: { value: 'john@example.com' },
    });
    fireEvent.change(screen.getByLabelText(/message/i), {
      target: { value: 'Too short' },
    });

    fireEvent.click(screen.getByRole('button', { name: /send/i }));

    expect(
      await screen.findByText(/message must be at least 80 characters long/i)
    ).toBeInTheDocument();
    expect(sendContactMessage).not.toHaveBeenCalled();
  });

  it('submits successfully and shows thank-you message', async () => {
    (sendContactMessage as jest.Mock).mockResolvedValueOnce({ success: true });

    render(<ContactUs />);

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'John Doe' },
    });
    fireEvent.change(screen.getByLabelText(/email/i), {
      target: { value: 'john@example.com' },
    });
    fireEvent.change(screen.getByLabelText(/message/i), {
      target: { value: VALID_MESSAGE },
    });

    fireEvent.click(screen.getByRole('button', { name: /send/i }));

    await waitFor(() => {
      expect(
        screen.getByText(/your message has been sent successfully/i)
      ).toBeInTheDocument();
    });

    expect(screen.queryByRole('form')).not.toBeInTheDocument();
  });

  it('shows server error when API fails', async () => {
    (sendContactMessage as jest.Mock).mockRejectedValueOnce(
      new Error('Server error')
    );

    render(<ContactUs />);

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'Jane Doe' },
    });
    fireEvent.change(screen.getByLabelText(/email/i), {
      target: { value: 'jane@example.com' },
    });
    fireEvent.change(screen.getByLabelText(/message/i), {
      target: { value: VALID_MESSAGE },
    });

    fireEvent.click(screen.getByRole('button', { name: /send/i }));

    expect(await screen.findByText(/server error/i)).toBeInTheDocument();
  });
});
